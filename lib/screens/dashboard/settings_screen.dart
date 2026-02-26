import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../utils/app_styles.dart';
import '../../widgets/custom_bottom_nav.dart';
import '../../widgets/fade_slide_y.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:math' as math;
import '../../main.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with SingleTickerProviderStateMixin {
  bool _notificationsEnabled = true;
  late AnimationController _bellController;

  @override
  void initState() {
    super.initState();
    _bellController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _loadNotificationPref();
  }

  Future<void> _loadNotificationPref() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _notificationsEnabled = prefs.getBool('notifications_enabled') ?? true;
    });
    if (_notificationsEnabled && mounted) {
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted) _playBellAnimation();
      });
    }
  }

  Future<void> _toggleNotification(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('notifications_enabled', value);
    setState(() {
      _notificationsEnabled = value;
    });
    if (_notificationsEnabled) {
      _playBellAnimation();
    }
  }

  @override
  void dispose() {
    _bellController.dispose();
    super.dispose();
  }

  void _playBellAnimation() {
    _bellController.forward(from: 0.0).then((_) {
      _bellController.reverse();
    });
  }

  void _onNavTap(int index) {
    if (index == 0) Navigator.of(context).pushReplacementNamed('/dashboard');
    if (index == 1) Navigator.of(context).pushReplacementNamed('/history');
    if (index == 2) return;
    if (index == 3) Navigator.of(context).pushReplacementNamed('/profile');
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        showGeneralDialog(
          context: context,
          barrierDismissible: true,
          barrierLabel: 'Dismiss',
          transitionDuration: const Duration(milliseconds: 250),
          pageBuilder: (context, animation, secondaryAnimation) {
            return Dialog(
              backgroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Exit App',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: AppStyles.textDark,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Are you sure you want to exit?',
                      style: TextStyle(
                        fontSize: 14,
                        color: AppStyles.textGray,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        OutlinedButton(
                          onPressed: () => Navigator.of(context).pop(),
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(
                              color: AppStyles.textGray.withValues(alpha: 0.3),
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 28,
                              vertical: 12,
                            ),
                          ),
                          child: const Text(
                            'Cancel',
                            style: TextStyle(
                              color: AppStyles.textGray,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        ElevatedButton(
                          onPressed: () => SystemNavigator.pop(),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red.shade600,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 28,
                              vertical: 12,
                            ),
                            elevation: 0,
                          ),
                          child: const Text(
                            'Exit',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
          transitionBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(
              opacity: animation,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.85, end: 1.0).animate(
                  CurvedAnimation(parent: animation, curve: Curves.easeOutBack),
                ),
                child: child,
              ),
            );
          },
        );
      },
      child: Scaffold(
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
                      _buildSectionHeader('Preferences'),
                      _buildNotificationToggle(),
                      const Divider(height: 1, color: Color(0xFFE2E8F0)),
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
                delay: const Duration(milliseconds: 220),
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
                      _buildSectionHeader('Account'),
                      _buildSettingsItem(
                        icon: Icons.lock_reset_rounded,
                        title: 'Change Password',
                        subtitle: 'Update your account password',
                        isDestructive: false,
                        onTap: () => Navigator.of(
                          context,
                        ).pushNamed('/forgot_password_face_verify'),
                      ),
                      const Divider(height: 1, color: Color(0xFFE2E8F0)),
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
                        onTap: () {
                          HapticFeedback.lightImpact();
                          Navigator.of(context).pushReplacementNamed('/home');
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: CustomBottomNav(currentIndex: 2, onTap: _onNavTap),
      ),
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

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 20, right: 20, top: 20, bottom: 8),
      child: Row(
        children: [
          Text(
            title.toUpperCase(),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.5,
              color: AppStyles.textGray.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNotificationToggle() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return InkWell(
      onTap: () => _toggleNotification(!_notificationsEnabled),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _notificationsEnabled
                    ? theme.primaryColor.withValues(alpha: 0.15)
                    : Colors.grey.withValues(alpha: isDark ? 0.2 : 0.1),
                shape: BoxShape.circle,
                boxShadow: _notificationsEnabled
                    ? [
                        BoxShadow(
                          color: theme.primaryColor.withValues(alpha: 0.2),
                          blurRadius: 12,
                          spreadRadius: 2,
                        ),
                      ]
                    : null,
              ),
              child: AnimatedBuilder(
                animation: _bellController,
                builder: (context, child) {
                  // A gentle shake oscillation
                  final angle =
                      math.sin(_bellController.value * math.pi * 2) * 0.2;
                  return Transform.rotate(angle: angle, child: child);
                },
                child: Icon(
                  _notificationsEnabled
                      ? Icons.notifications_active_rounded
                      : Icons.notifications_off_rounded,
                  color: _notificationsEnabled
                      ? theme.primaryColor
                      : Colors.grey.shade500,
                  size: 26,
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Notifications',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color:
                          theme.textTheme.displayLarge?.color ??
                          AppStyles.textDark,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _notificationsEnabled
                        ? 'Push notifications enabled'
                        : 'Push notifications disabled',
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
