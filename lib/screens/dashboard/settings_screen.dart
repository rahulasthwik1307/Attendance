import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../utils/app_styles.dart';
import '../../widgets/custom_bottom_nav.dart';
import '../../widgets/fade_slide_y.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:math' as math;
import '../../main.dart';
import '../../services/notification_service.dart';

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
      // Save FCM token to Supabase — student will now receive notifications
      await NotificationService.enableNotifications();
    } else {
      // Remove FCM token from Supabase — student will stop receiving notifications
      await NotificationService.disableNotifications();
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

  void _showAboutDialog() {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Dismiss About',
      barrierColor: Colors.black.withValues(alpha: 0.54),
      transitionDuration: const Duration(milliseconds: 280),
      pageBuilder: (ctx, anim1, anim2) {
        return const _AboutAppDialog();
      },
      transitionBuilder: (ctx, anim1, anim2, child) {
        final curved = Curves.easeOutCubic.transform(anim1.value);
        return Transform.scale(
          scale: 0.92 + (0.08 * curved),
          child: Opacity(
            opacity: anim1.value.clamp(0.0, 1.0),
            child: child,
          ),
        );
      },
    );
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
                        ).pushNamed(
                          '/face_verification',
                          arguments: 'password_reset',
                        ),
                      ),
                      const Divider(height: 1, color: Color(0xFFE2E8F0)),
                      _buildSettingsItem(
                        icon: Icons.info_outline_rounded,
                        title: 'About App',
                        subtitle: 'Version, college and app information',
                        onTap: () => _showAboutDialog(),
                      ),
                      const Divider(height: 1, color: Color(0xFFE2E8F0)),
                      _buildSettingsItem(
                        icon: Icons.logout_rounded,
                        title: 'Logout',
                        subtitle: 'Sign out from your account',
                        isDestructive: true,
                        onTap: () async {
                          HapticFeedback.lightImpact();
                          await NotificationService.removeTokenOnLogout();
                          await Supabase.instance.client.auth.signOut();
                          if (!context.mounted) return;
                          Navigator.of(context).pushNamedAndRemoveUntil(
                            '/home',
                            (route) => false,
                          );
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
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
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
              color: isDark
                  ? Colors.white.withValues(alpha: 0.7)
                  : AppStyles.textDark.withValues(alpha: 0.55),
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

class _AboutAppDialog extends StatefulWidget {
  const _AboutAppDialog();

  @override
  State<_AboutAppDialog> createState() => _AboutAppDialogState();
}

class _AboutAppDialogState extends State<_AboutAppDialog>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animController;
  late final Animation<double> _headerFade;
  late final Animation<Offset> _headerSlide;
  late final Animation<double> _infoFade;
  late final Animation<Offset> _infoSlide;
  late final Animation<double> _descFade;
  late final Animation<double> _buttonFade;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );

    _headerFade = CurvedAnimation(
      parent: _animController,
      curve: const Interval(0.0, 0.55, curve: Curves.easeOutCubic),
    );
    _headerSlide = Tween<Offset>(
      begin: const Offset(0, 0.08),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(
        parent: _animController,
        curve: const Interval(0.0, 0.55, curve: Curves.easeOutCubic),
      ),
    );

    _infoFade = CurvedAnimation(
      parent: _animController,
      curve: const Interval(0.20, 0.75, curve: Curves.easeOutCubic),
    );
    _infoSlide = Tween<Offset>(
      begin: const Offset(0, 0.06),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(
        parent: _animController,
        curve: const Interval(0.20, 0.75, curve: Curves.easeOutCubic),
      ),
    );

    _descFade = CurvedAnimation(
      parent: _animController,
      curve: const Interval(0.40, 0.88, curve: Curves.easeOutCubic),
    );

    _buttonFade = CurvedAnimation(
      parent: _animController,
      curve: const Interval(0.55, 1.0, curve: Curves.easeOutCubic),
    );

    _animController.forward();
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final primaryColor = theme.primaryColor;
    final surfaceColor = isDark
        ? const Color(0xFF1E1E20)
        : (theme.cardTheme.color ?? Colors.white);
    final textDarkColor = isDark
        ? Colors.white
        : (theme.textTheme.displayLarge?.color ?? AppStyles.textDark);
    final textGrayColor = isDark
        ? Colors.white.withValues(alpha: 0.65)
        : (theme.textTheme.bodyMedium?.color ?? AppStyles.textGray);
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.1)
        : const Color(0xFFE2E8F0);
    final groupBgColor = isDark
        ? const Color(0xFF252529)
        : const Color(0xFFF8FAFC);
    final groupBorderColor = isDark
        ? primaryColor.withValues(alpha: 0.35)
        : primaryColor.withValues(alpha: 0.28);
    final dividerColor = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : primaryColor.withValues(alpha: 0.16);

    return Center(
      child: Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
        child: Container(
          constraints: BoxConstraints(
            maxWidth: 390,
            maxHeight: MediaQuery.sizeOf(context).height * 0.88,
          ),
          decoration: BoxDecoration(
            color: surfaceColor,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: borderColor, width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
                blurRadius: 24,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // 1. App Identity Header
                  FadeTransition(
                    opacity: _headerFade,
                    child: SlideTransition(
                      position: _headerSlide,
                      child: Column(
                        children: [
                          Container(
                            width: 60,
                            height: 60,
                            decoration: BoxDecoration(
                              color: primaryColor.withValues(
                                alpha: isDark ? 0.18 : 0.1,
                              ),
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: primaryColor.withValues(
                                  alpha: isDark ? 0.3 : 0.2,
                                ),
                                width: 1.2,
                              ),
                            ),
                            child: Icon(
                              Icons.school_rounded,
                              size: 30,
                              color: primaryColor,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Factor Attendance',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 21,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.3,
                              color: textDarkColor,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? Colors.white.withValues(alpha: 0.08)
                                  : const Color(0xFFEDF2F7),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              'Version 1.0.0',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: textGrayColor,
                                letterSpacing: 0.2,
                              ),
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            'Smart Attendance System',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w500,
                              color: textGrayColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 14),
                  Divider(height: 1, color: borderColor),
                  const SizedBox(height: 12),

                  // 2. System & Technology Section (One Cohesive Outer Card)
                  FadeTransition(
                    opacity: _infoFade,
                    child: SlideTransition(
                      position: _infoSlide,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(left: 2, bottom: 8),
                            child: Text(
                              'SYSTEM & TECHNOLOGY',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.2,
                                color: textGrayColor,
                              ),
                            ),
                          ),
                          Container(
                            decoration: BoxDecoration(
                              color: groupBgColor,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: groupBorderColor,
                                width: 1.3,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: primaryColor.withValues(
                                    alpha: isDark ? 0.08 : 0.05,
                                  ),
                                  blurRadius: 12,
                                  spreadRadius: 1,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 4,
                            ),
                            child: Column(
                              children: [
                                _AboutInfoTile(
                                  icon: Icons.account_balance_rounded,
                                  accentColor: const Color(0xFF2563EB),
                                  label: 'College',
                                  value: 'NNRG College, Hyderabad',
                                  isDark: isDark,
                                  textDarkColor: textDarkColor,
                                ),
                                Container(
                                  height: 1.3,
                                  color: dividerColor,
                                  margin: const EdgeInsets.symmetric(
                                    horizontal: 2,
                                  ),
                                ),
                                _AboutInfoTile(
                                  icon: Icons.security_rounded,
                                  accentColor: const Color(0xFF6366F1),
                                  label: 'Authentication',
                                  value: 'Face Recognition + Geofence',
                                  isDark: isDark,
                                  textDarkColor: textDarkColor,
                                ),
                                Container(
                                  height: 1.3,
                                  color: dividerColor,
                                  margin: const EdgeInsets.symmetric(
                                    horizontal: 2,
                                  ),
                                ),
                                _AboutInfoTile(
                                  icon: Icons.cloud_outlined,
                                  accentColor: const Color(0xFF0D9488),
                                  label: 'Backend',
                                  value: 'Supabase + Next.js',
                                  isDark: isDark,
                                  textDarkColor: textDarkColor,
                                ),
                                Container(
                                  height: 1.3,
                                  color: dividerColor,
                                  margin: const EdgeInsets.symmetric(
                                    horizontal: 2,
                                  ),
                                ),
                                _AboutInfoTile(
                                  icon: Icons.code_rounded,
                                  accentColor: const Color(0xFF8B5CF6),
                                  label: 'Built with',
                                  value: 'Flutter + TensorFlow Lite',
                                  isDark: isDark,
                                  textDarkColor: textDarkColor,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 14),

                  // 3. Description
                  FadeTransition(
                    opacity: _descFade,
                    child: Text(
                      'Smart attendance management for NNRG College. Secure, fast and reliable with AI-powered face verification.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.45,
                        color: textGrayColor,
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),

                  // 4. Close Button
                  FadeTransition(
                    opacity: _buttonFade,
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () => Navigator.of(context).pop(),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: primaryColor,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          elevation: 0,
                        ),
                        child: const Text(
                          'Close',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AboutInfoTile extends StatelessWidget {
  final IconData icon;
  final Color accentColor;
  final String label;
  final String value;
  final bool isDark;
  final Color textDarkColor;

  const _AboutInfoTile({
    required this.icon,
    required this.accentColor,
    required this.label,
    required this.value,
    required this.isDark,
    required this.textDarkColor,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: accentColor.withValues(alpha: isDark ? 0.18 : 0.10),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: accentColor.withValues(alpha: isDark ? 0.30 : 0.20),
                width: 1,
              ),
            ),
            child: Icon(
              icon,
              size: 19,
              color: accentColor,
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label.toUpperCase(),
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.0,
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.5)
                        : const Color(0xFF64748B),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                    color: textDarkColor,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}


