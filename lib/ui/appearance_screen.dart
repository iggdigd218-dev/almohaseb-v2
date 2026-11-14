// شاشة المظهر المستقلة: حجم الخط، اللغة، والأصوات/الاهتزاز.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/l10n.dart';
import '../core/sfx.dart';
import '../core/theme.dart';
import '../data/providers.dart';

/// بطاقة اختيار لغة التطبيق (العربية / English) مع حفظ فوري في SharedPreferences وتطبيق الاتجاه RTL/LTR دون إعادة تشغيل.
class LanguageSelectorCard extends ConsumerWidget {
  const LanguageSelectorCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentLocale = ref.watch(appLocaleProvider);
    final isEn = currentLocale.languageCode.toLowerCase().startsWith('en');
    final l10n = AppLocalizations.of(context);
    final primary = AppColors.primaryOf(context);

    return Card(
      key: const ValueKey('settings_language_card'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.language_rounded, color: primary, size: 21),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.languageLabel,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 14.5,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    isEn ? 'English' : 'العربية',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                      color: primary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('lang_option_ar'),
                    onPressed: () async {
                      Sfx.tap();
                      await saveAppLocale(ref, const Locale('ar'));
                    },
                    style: OutlinedButton.styleFrom(
                      backgroundColor:
                          !isEn ? primary.withValues(alpha: 0.12) : null,
                      side: BorderSide(
                        color: !isEn
                            ? primary
                            : Theme.of(context).dividerColor,
                        width: !isEn ? 1.6 : 1,
                      ),
                    ),
                    icon: Icon(
                      !isEn
                          ? Icons.check_circle_rounded
                          : Icons.circle_outlined,
                      size: 18,
                      color: !isEn ? primary : AppColors.text3Of(context),
                    ),
                    label: Text(
                      'العربية',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: !isEn ? primary : AppColors.textOf(context),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('lang_option_en'),
                    onPressed: () async {
                      Sfx.tap();
                      await saveAppLocale(ref, const Locale('en'));
                    },
                    style: OutlinedButton.styleFrom(
                      backgroundColor:
                          isEn ? primary.withValues(alpha: 0.12) : null,
                      side: BorderSide(
                        color: isEn
                            ? primary
                            : Theme.of(context).dividerColor,
                        width: isEn ? 1.6 : 1,
                      ),
                    ),
                    icon: Icon(
                      isEn
                          ? Icons.check_circle_rounded
                          : Icons.circle_outlined,
                      size: 18,
                      color: isEn ? primary : AppColors.text3Of(context),
                    ),
                    label: Text(
                      'English',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: isEn ? primary : AppColors.textOf(context),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class ThemeModeSelectorCard extends ConsumerWidget {
  const ThemeModeSelectorCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentMode = ref.watch(themeModeProvider);
    final primary = AppColors.primaryOf(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  currentMode == ThemeMode.dark
                      ? Icons.dark_mode_rounded
                      : (currentMode == ThemeMode.system
                          ? Icons.brightness_auto_rounded
                          : Icons.light_mode_rounded),
                  color: primary,
                  size: 21,
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'وضع المظهر (النهاري / الليلي)',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            RadioListTile<ThemeMode>(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: ThemeMode.light,
              groupValue: currentMode,
              secondary: const Icon(
                Icons.light_mode_rounded,
                color: Color(0xFFD97706),
              ),
              title: const Text(
                'الوضع النهاري (فاتح دائماً)',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
              ),
              subtitle: const Text(
                'ثابت ومستقل تماماً عن إعدادات الجهاز',
                style: TextStyle(fontSize: 11.5),
              ),
              onChanged: (v) async {
                if (v == null) return;
                Sfx.tap();
                await saveAppThemeMode(ref, v);
              },
            ),
            const Divider(height: 1),
            RadioListTile<ThemeMode>(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: ThemeMode.dark,
              groupValue: currentMode,
              secondary: const Icon(
                Icons.dark_mode_rounded,
                color: Color(0xFF6366F1),
              ),
              title: const Text(
                'الوضع الليلي (داكن دائماً)',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
              ),
              subtitle: const Text(
                'مريح للعين في الإضاءة المنخفضة بشكل دائم',
                style: TextStyle(fontSize: 11.5),
              ),
              onChanged: (v) async {
                if (v == null) return;
                Sfx.tap();
                await saveAppThemeMode(ref, v);
              },
            ),
            const Divider(height: 1),
            RadioListTile<ThemeMode>(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: ThemeMode.system,
              groupValue: currentMode,
              secondary: Icon(
                Icons.brightness_auto_rounded,
                color: primary,
              ),
              title: const Text(
                'حسب إعدادات الجهاز (تلقائي)',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
              ),
              subtitle: const Text(
                'يتبع وضع النظام (نهاري أو ليلي) تلقائياً',
                style: TextStyle(fontSize: 11.5),
              ),
              onChanged: (v) async {
                if (v == null) return;
                Sfx.tap();
                await saveAppThemeMode(ref, v);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class AppearanceScreen extends ConsumerWidget {
  const AppearanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(settingsProvider).valueOrNull ?? {};
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('المظهر والأصوات'))),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          const LanguageSelectorCard(),
          const SizedBox(height: 12),
          const ThemeModeSelectorCard(),
          const SizedBox(height: 12),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.format_size),
                  title: const Text('خط أكبر في لوحة التحكم'),
                  subtitle: const Text('تكبير الأرقام والعناوين'),
                  value: (st['bigText'] ?? '1') == '1',
                  onChanged: (v) async {
                    await ref
                        .read(repoProvider)
                        .setSetting('bigText', v ? '1' : '0');
                    ref.invalidate(settingsProvider);
                  },
                ),
                const Divider(height: 1),
                // (دفعة 58 — متطلب 7) الوضع الصامت الشامل: يكتم كل الأصوات
                // والاهتزازات وحتى صوت إشعارات النظام الخارجية بمفتاح واحد.
                SwitchListTile(
                  secondary: const Icon(Icons.volume_off_outlined),
                  title: const Text('الوضع الصامت'),
                  subtitle: const Text(
                      'كتم كل الأصوات والاهتزازات — تصل الإشعارات صامتة'),
                  value: (st['sfxMute'] ?? '0') == '1',
                  onChanged: (v) async {
                    await ref
                        .read(repoProvider)
                        .setSetting('sfxMute', v ? '1' : '0');
                    Sfx.applySettings(
                      sound: (st['sfxSound'] ?? '1') == '1',
                      haptic: (st['sfxHaptic'] ?? '1') == '1',
                      mute: v,
                    );
                    if (!v) Sfx.pop();
                    ref.invalidate(settingsProvider);
                  },
                ),
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(Icons.volume_up_outlined),
                  title: const Text('الأصوات'),
                  subtitle: const Text('نغمات النجاح والخطأ والأزرار'),
                  value: (st['sfxSound'] ?? '1') == '1',
                  onChanged: (v) async {
                    await ref
                        .read(repoProvider)
                        .setSetting('sfxSound', v ? '1' : '0');
                    Sfx.applySettings(
                        sound: v, haptic: (st['sfxHaptic'] ?? '1') == '1');
                    if (v) Sfx.pop();
                    ref.invalidate(settingsProvider);
                  },
                ),
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(Icons.vibration_outlined),
                  title: const Text('الاهتزاز'),
                  subtitle: const Text('ردود اهتزازية عند الحفظ والدفع'),
                  value: (st['sfxHaptic'] ?? '1') == '1',
                  onChanged: (v) async {
                    await ref
                        .read(repoProvider)
                        .setSetting('sfxHaptic', v ? '1' : '0');
                    Sfx.applySettings(
                        sound: (st['sfxSound'] ?? '1') == '1', haptic: v);
                    if (v) Sfx.success();
                    ref.invalidate(settingsProvider);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // معاينة الأصوات: جرّب كل نوع تفاعل قبل استخدامه فعلياً.
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.music_note_outlined,
                          color: AppColors.primaryOf(context), size: 20),
                      const SizedBox(width: 8),
                      const Text('معاينة الأصوات والاهتزازات',
                          style: TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 14.5)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final (_, label, play) in Sfx.previewable())
                        ActionChip(
                          avatar: const Icon(Icons.play_arrow, size: 16),
                          label: Text(label,
                              style: const TextStyle(fontSize: 12)),
                          onPressed: play,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
