import 'package:flutter/material.dart';
import '../utils/app_styles.dart';
import '../widgets/custom_bottom_nav.dart';
import '../widgets/fade_slide_y.dart';
import '../main.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  void _onNavTap(int index) {
    if (index == 0) Navigator.of(context).pushReplacementNamed('/dashboard');
    if (index == 1) Navigator.of(context).pushReplacementNamed('/history');
    if (index == 2) return;
    if (index == 3) Navigator.of(context).pushReplacementNamed('/profile');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: Text(
          'Settings',
          style: TextStyle(
            color:
                Theme.of(context).textTheme.displayLarge?.color ??
                AppStyles.textDark,
            fontWeight: FontWeight.bold,
            fontSize: 24,
          ),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24.0),
          children: [
            FadeSlideY(
              delay: const Duration(milliseconds: 100),
              child: Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).cardTheme.color ?? Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    ValueListenableBuilder<ThemeMode>(
                      valueListenable: appThemeNotifier,
                      builder: (context, currentMode, _) {
                        return _buildSettingsSwitch(
                          icon: currentMode == ThemeMode.dark
                              ? Icons.dark_mode_outlined
                              : Icons.light_mode_outlined,
                          title: 'App Theme',
                          subtitle: currentMode == ThemeMode.dark
                              ? 'Dark Mode Active'
                              : 'Light Mode Active',
                          value: currentMode == ThemeMode.dark,
                          onChanged: (val) {
                            appThemeNotifier.value = val
                                ? ThemeMode.dark
                                : ThemeMode.light;
                          },
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            FadeSlideY(
              delay: const Duration(milliseconds: 200),
              child: Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).cardTheme.color ?? Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    _buildSettingsItem(
                      icon: Icons.info_outline_rounded,
                      title: 'About App',
                      subtitle: 'Learn more about this application',
                      onTap: () {},
                    ),
                    const Divider(height: 1, color: Color(0xFFE2E8F0)),
                    _buildSettingsItem(
                      icon: Icons.logout_rounded,
                      title: 'Logout',
                      subtitle: 'Sign out from your account',
                      isDestructive: true,
                      onTap: () =>
                          Navigator.of(context).pushReplacementNamed('/home'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: CustomBottomNav(currentIndex: 2, onTap: _onNavTap),
    );
  }

  Widget _buildSettingsItem({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool isDestructive = false,
  }) {
    final theme = Theme.of(context);
    final titleColor = isDestructive
        ? AppStyles.errorRed
        : (theme.textTheme.displayLarge?.color ?? AppStyles.textDark);
    final iconColor = isDestructive ? AppStyles.errorRed : theme.primaryColor;
    final iconBgColor = isDestructive
        ? AppStyles.errorRed.withValues(alpha: 0.1)
        : theme.primaryColor.withValues(alpha: 0.1);

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: iconBgColor,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: iconColor),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: titleColor,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color:
                          theme.textTheme.bodyMedium?.color ??
                          AppStyles.textGray,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: theme.textTheme.bodyMedium?.color ?? Colors.grey.shade400,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingsSwitch({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final theme = Theme.of(context);
    final titleColor =
        theme.textTheme.displayLarge?.color ?? AppStyles.textDark;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.primaryColor.withValues(
                alpha: 0.15,
              ), // Slightly more opaque
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: theme.primaryColor.withValues(
                    alpha: 0.2,
                  ), // Subtle glow
                  blurRadius: 12,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Icon(
              icon,
              color: theme.primaryColor,
              size: 26,
            ), // Slightly larger icon
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: titleColor,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color:
                        theme.textTheme.bodyMedium?.color ?? AppStyles.textGray,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: theme.primaryColor,
            activeTrackColor: theme.primaryColor.withValues(alpha: 0.3),
            inactiveThumbColor: Colors.grey.shade400,
            inactiveTrackColor: theme.scaffoldBackgroundColor,
          ),
        ],
      ),
    );
  }
}
