import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/category_tree.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('Multi-level Subcategories (Open-Depth Tree)', () {
    late Repo repo;

    setUp(() async {
      final db = await databaseFactory.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
        ),
      );
      await AppDatabase.createSchema(db);
      await AppDatabase.migrateToV23(db);
      await AppDatabase.migrateToV24(db);
      await AppDatabase.ensureLatestColumns(db);
      await db.delete('item_categories');
      await db.delete('items');
      await db.delete('sections');
      await db.delete('operations');
      repo = Repo(databaseProvider: () async => db);
      await repo.initSyncInfra();
    });

    test(
      'Builds 4-level category tree, exposes child branches at every level, and filters items & valuations recursively across all descendants',
      () async {
        final now = DateTime.now();

        // 1. Create section: الصيانة
        final maintenanceSecId = await repo.saveSection(
          Section(name: 'الصيانة', createdAt: now, updatedAt: now),
        );

        // 2. Create 4-level hierarchy:
        // Level 1 (Root): شاشات
        final screensId = await repo.saveItemCategory(
          ItemCategory(
            name: 'شاشات',
            sectionId: maintenanceSecId,
            createdAt: now,
            updatedAt: now,
          ),
        );

        // Level 2 (Sub 1): Samsung (parent = شاشات)
        final samsungId = await repo.saveItemCategory(
          ItemCategory(
            name: 'Samsung',
            sectionId: maintenanceSecId,
            parentId: screensId,
            createdAt: now,
            updatedAt: now,
          ),
        );

        // Level 3 (Sub 2): فئة A (parent = Samsung)
        final seriesAId = await repo.saveItemCategory(
          ItemCategory(
            name: 'فئة A',
            sectionId: maintenanceSecId,
            parentId: samsungId,
            createdAt: now,
            updatedAt: now,
          ),
        );

        // Level 3 (Sub 2 sibling): فئة S (parent = Samsung)
        final seriesSId = await repo.saveItemCategory(
          ItemCategory(
            name: 'فئة S',
            sectionId: maintenanceSecId,
            parentId: samsungId,
            createdAt: now,
            updatedAt: now,
          ),
        );

        // Level 4 (Sub 3): أوليد (parent = فئة A)
        final oledId = await repo.saveItemCategory(
          ItemCategory(
            name: 'أوليد',
            sectionId: maintenanceSecId,
            parentId: seriesAId,
            createdAt: now,
            updatedAt: now,
          ),
        );

        // 3. Verify recursive tree building via repo.itemCategoryTree()
        final tree = await repo.itemCategoryTree();
        final rootScreens = findCategoryInTree(screensId, tree);
        expect(rootScreens, isNotNull);
        expect(rootScreens!.children.map((c) => c.id), contains(samsungId));

        // Verify selecting Samsung exposes its direct children (فئة A, فئة S) for the drill-down strip
        final samsungNode = findCategoryInTree(samsungId, tree);
        expect(samsungNode, isNotNull);
        expect(
          samsungNode!.children.map((c) => c.name).toList(),
          containsAll(['فئة A', 'فئة S']),
        );

        // Verify selecting فئة A exposes its level-4 child (أوليد)
        final seriesANode = findCategoryInTree(seriesAId, tree);
        expect(seriesANode, isNotNull);
        expect(
          seriesANode!.children.map((c) => c.name).toList(),
          equals(['أوليد']),
        );

        // 4. Add items at Level 2 (Samsung), Level 3 (فئة A), and Level 4 (أوليد)
        final itemL2Id = await repo.saveItem(
          Item(
            name: 'شاشة سامسونج عامة',
            category: 'Samsung',
            categoryId: samsungId,
            sectionId: maintenanceSecId,
            buyPrice: 100,
            sellPrice: 150,
            quantity: 2, // cost = 200, sell = 300
            createdAt: now,
            updatedAt: now,
          ),
        );

        final itemL3Id = await repo.saveItem(
          Item(
            name: 'شاشة A52 وكالة',
            category: 'فئة A',
            categoryId: seriesAId,
            sectionId: maintenanceSecId,
            buyPrice: 200,
            sellPrice: 280,
            quantity: 3, // cost = 600, sell = 840
            createdAt: now,
            updatedAt: now,
          ),
        );

        final itemL4Id = await repo.saveItem(
          Item(
            name: 'شاشة A73 أوليد',
            category: 'أوليد',
            categoryId: oledId,
            sectionId: maintenanceSecId,
            buyPrice: 300,
            sellPrice: 420,
            quantity: 1, // cost = 300, sell = 420
            createdAt: now,
            updatedAt: now,
          ),
        );

        final allCats = await repo.itemCategories();
        final allItems = await repo.items();

        // 5. Verify getCategoryAndAllDescendantIds at Level 1 (شاشات)
        final screensDescendants = getCategoryAndAllDescendantIds(
          screensId,
          allCats,
        );
        expect(
          screensDescendants,
          containsAll([screensId, samsungId, seriesAId, seriesSId, oledId]),
        );
        final repoDescendants = await repo.getCategoryAndAllDescendantIds(
          screensId,
        );
        expect(repoDescendants, equals(screensDescendants));

        // Filtering by Level 1 (شاشات) returns items from Level 2, Level 3, and Level 4
        final itemsInScreens = allItems
            .where((i) => screensDescendants.contains(i.categoryId))
            .toList();
        expect(
          itemsInScreens.map((i) => i.id),
          containsAll([itemL2Id, itemL3Id, itemL4Id]),
        );

        // 6. Verify getCategoryAndAllDescendantIds at Level 2 (Samsung)
        final samsungDescendants = getCategoryAndAllDescendantIds(
          samsungId,
          allCats,
        );
        expect(
          samsungDescendants,
          equals({samsungId, seriesAId, seriesSId, oledId}),
        );
        final itemsInSamsung = allItems
            .where((i) => samsungDescendants.contains(i.categoryId))
            .toList();
        expect(
          itemsInSamsung.map((i) => i.id),
          containsAll([itemL2Id, itemL3Id, itemL4Id]),
        );

        // Verify total cost (رأس المال) and selling value for Samsung (includes Level 2 + Level 3 + Level 4)
        final samsungTotalCost = itemsInSamsung.fold<double>(
          0,
          (sum, i) => sum + (i.quantity > 0 ? i.quantity * i.buyPrice : 0),
        );
        final samsungTotalSell = itemsInSamsung.fold<double>(
          0,
          (sum, i) => sum + (i.quantity > 0 ? i.quantity * i.sellPrice : 0),
        );
        expect(samsungTotalCost, equals(200 + 600 + 300)); // 1100
        expect(samsungTotalSell, equals(300 + 840 + 420)); // 1560

        // 7. Verify getCategoryAndAllDescendantIds at Level 3 (فئة A)
        final seriesADescendants = getCategoryAndAllDescendantIds(
          seriesAId,
          allCats,
        );
        expect(seriesADescendants, equals({seriesAId, oledId}));
        final itemsInSeriesA = allItems
            .where((i) => seriesADescendants.contains(i.categoryId))
            .toList();
        expect(
          itemsInSeriesA.map((i) => i.id),
          containsAll([itemL3Id, itemL4Id]),
        );
        expect(itemsInSeriesA.map((i) => i.id), isNot(contains(itemL2Id)));

        // 8. Verify full path formatting for dropdowns and breadcrumbs
        final oledPath = getCategoryPath(oledId, allCats);
        expect(
          oledPath.map((c) => c.name).toList(),
          equals(['شاشات', 'Samsung', 'فئة A', 'أوليد']),
        );
        expect(
          formatCategoryPath(oledId, allCats),
          equals('شاشات › Samsung › فئة A › أوليد'),
        );
      },
    );
  });
}
