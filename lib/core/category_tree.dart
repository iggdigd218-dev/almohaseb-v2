// أدوات الشجرة متعددة المستويات لفئات الأصناف (Multi-level Item Category Tree).
//
// تدعم شجرة مفتوحة العمق: فئة رئيسية > فرعية 1 > فرعية 2 > فرعية 3 ...
// مع دوال استخراج المعرفات شجرياً، وبناء المسارات، والتصفية الشاملة.
library;

import 'models.dart';

/// استخراج معرّف الفئة مضافاً إليه جميع معرّفات الفئات الأبناء والأحفاد التابعة لها شجرياً لأي عمق.
///
/// يدعم قوائم الفئات المسطحة (flat) وقوائم الشجرة (tree with children) مع حماية تامة من الحلقات الدائرية.
Set<int> getCategoryAndAllDescendantIds(
  int categoryId,
  Iterable<ItemCategory> categories,
) {
  final result = <int>{categoryId};
  final childrenByParent = <int, List<int>>{};

  void indexNode(ItemCategory node) {
    if (node.id != null) {
      if (node.parentId != null) {
        childrenByParent
            .putIfAbsent(node.parentId!, () => <int>[])
            .add(node.id!);
      }
      for (final child in node.children) {
        if (child.id != null) {
          childrenByParent
              .putIfAbsent(node.id!, () => <int>[])
              .add(child.id!);
          indexNode(child);
        }
      }
    }
  }

  for (final cat in categories) {
    indexNode(cat);
  }

  final queue = <int>[categoryId];
  final visited = <int>{categoryId};
  while (queue.isNotEmpty) {
    final current = queue.removeLast();
    final kids = childrenByParent[current];
    if (kids != null) {
      for (final kid in kids) {
        result.add(kid);
        if (visited.add(kid)) {
          queue.add(kid);
        }
      }
    }
  }
  return result;
}

/// البحث عن فئة بمعرفها داخل شجرة أو قائمة فئات.
ItemCategory? findCategoryInTree(int? id, Iterable<ItemCategory> categories) {
  if (id == null) return null;
  for (final cat in categories) {
    if (cat.id == id) return cat;
    final inChildren = findCategoryInTree(id, cat.children);
    if (inChildren != null) return inChildren;
  }
  return null;
}

/// استخراج مسار الفئة الكامل من الجذر وصولاً إلى الفئة المستهدفة.
///
/// مثال: `[شاشات, Samsung, فئة A]`
List<ItemCategory> getCategoryPath(
  int? targetId,
  Iterable<ItemCategory> categories,
) {
  if (targetId == null) return const [];

  final byId = <int, ItemCategory>{};
  final parentIdOf = <int, int>{};

  void indexNode(ItemCategory node, int? explicitParentId) {
    final id = node.id;
    if (id == null) return;
    byId[id] = node;
    final pId = node.parentId ?? explicitParentId;
    if (pId != null) {
      parentIdOf[id] = pId;
    }
    for (final ch in node.children) {
      indexNode(ch, id);
    }
  }

  for (final c in categories) {
    indexNode(c, c.parentId);
  }

  final path = <ItemCategory>[];
  var cursor = byId[targetId];
  final guard = <int>{};
  while (cursor != null && cursor.id != null && guard.add(cursor.id!)) {
    path.insert(0, cursor);
    final pId = parentIdOf[cursor.id!];
    cursor = pId != null ? byId[pId] : null;
  }
  return path;
}

/// تنسيق المسار الشجري للفئة كنص مقروء.
///
/// مثال: `شاشات › Samsung › فئة A`
String formatCategoryPath(
  int? categoryId,
  Iterable<ItemCategory> categories, {
  String separator = ' › ',
}) {
  final path = getCategoryPath(categoryId, categories);
  if (path.isEmpty) return 'عام';
  return path.map((c) => c.name).join(separator);
}

/// عنصر مرتب هرمياً مع بيان العمق (Depth) لتمثيله في القوائم المنسدلة.
class HierarchicalCategoryItem {
  final ItemCategory category;
  final int depth;
  final String pathLabel;

  const HierarchicalCategoryItem({
    required this.category,
    required this.depth,
    required this.pathLabel,
  });
}

/// ترتيب الفئات هرمياً بحيث تتبع كل فئة فرعية أباها المباشر في الترتيب مع بيان عمقها.
List<HierarchicalCategoryItem> sortCategoriesHierarchically(
  Iterable<ItemCategory> categories,
) {
  final all = categories.toList();
  final roots = <ItemCategory>[];
  final childrenByParent = <int, List<ItemCategory>>{};

  for (final c in all) {
    final p = c.parentId;
    if (p == null) {
      roots.add(c);
    } else {
      childrenByParent.putIfAbsent(p, () => <ItemCategory>[]).add(c);
    }
  }

  roots.sort((a, b) => a.name.compareTo(b.name));
  for (final list in childrenByParent.values) {
    list.sort((a, b) => a.name.compareTo(b.name));
  }

  final result = <HierarchicalCategoryItem>[];

  void traverse(ItemCategory node, int depth, List<String> parentNames) {
    final currentPath = [...parentNames, node.name];
    final pathLabel = depth == 0
        ? node.name
        : '${"  " * depth}↳ ${currentPath.join(" › ")}';

    result.add(
      HierarchicalCategoryItem(
        category: node,
        depth: depth,
        pathLabel: pathLabel,
      ),
    );

    // الأبناء إما من children المباشر أو من خريطة childrenByParent
    final kids = node.children.isNotEmpty
        ? node.children
        : (childrenByParent[node.id] ?? const <ItemCategory>[]);

    for (final child in kids) {
      traverse(child, depth + 1, currentPath);
    }
  }

  for (final root in roots) {
    traverse(root, 0, []);
  }

  // إضافة أي فئات معزولة لم ترتبط بشجرة
  final visitedIds = result.map((e) => e.category.id).toSet();
  for (final c in all) {
    if (c.id != null && !visitedIds.contains(c.id)) {
      result.add(
        HierarchicalCategoryItem(
          category: c,
          depth: c.parentId != null ? 1 : 0,
          pathLabel: c.parentId != null ? '↳ ${c.name}' : c.name,
        ),
      );
    }
  }

  return result;
}
