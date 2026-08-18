import 'package:flutter/material.dart';
import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../utils/app_styles.dart';
import '../../widgets/animated_button.dart';
import '../../widgets/fade_slide_y.dart';

enum _CheckState { pending, checking, success, error }

class QrPrecheckScreen extends StatefulWidget {
  const QrPrecheckScreen({super.key});

  @override
  State<QrPrecheckScreen> createState() => _QrPrecheckScreenState();
}

class _QrPrecheckScreenState extends State<QrPrecheckScreen> {
  _CheckState _attendanceState = _CheckState.checking;
  _CheckState _locationState = _CheckState.pending;
  bool _hasFailed = false;
  bool _isLocationOff = false;
  bool _isMockLocation = false;

  @override
  void initState() {
    super.initState();
    _runChecks();
  }

  Future<void> _runChecks() async {
    // ── Check 1: College Attendance ──────────────────────────────
    setState(() {
      _attendanceState = _CheckState.checking;
    });

    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) {
        setState(() => _attendanceState = _CheckState.error);
        _handleFailure();
        return;
      }

      final todayStr = DateTime.now().toIso8601String().split('T')[0];
      final records = await Supabase.instance.client
          .from('college_attendance')
          .select('id, status')
          .eq('student_id', user.id)
          .eq('date', todayStr)
          .eq('status', 'present')
          .limit(1);

      if (records.isEmpty) {
        setState(() => _attendanceState = _CheckState.error);
        _handleFailure();
        return;
      }

      setState(() {
        _attendanceState = _CheckState.success;
        _locationState = _CheckState.checking;
      });
    } catch (e) {
      debugPrint('[PRECHECK] Attendance check error: $e');
      setState(() => _attendanceState = _CheckState.error);
      _handleFailure();
      return;
    }

    // ── Check 2: Geofence from Supabase ─────────────────────────
    try {
      // Fetch geofence settings from Supabase — no hardcoded fallback
      final geoData = await Supabase.instance.client
          .from('geofence_settings')
          .select('latitude, longitude, radius_meters')
          .order('updated_at', ascending: false)
          .limit(1)
          .maybeSingle();

      if (geoData == null ||
          geoData['latitude'] == null ||
          geoData['longitude'] == null ||
          geoData['radius_meters'] == null) {
        debugPrint('[PRECHECK] No geofence settings found in Supabase');
        setState(() => _locationState = _CheckState.error);
        _handleFailure();
        return;
      }

      final double campusLat = (geoData['latitude'] as num).toDouble();
      final double campusLng = (geoData['longitude'] as num).toDouble();
      final double campusRadius = (geoData['radius_meters'] as num).toDouble();

      debugPrint(
        '[PRECHECK] Geofence: lat=$campusLat lng=$campusLng radius=$campusRadius',
      );

      // Check device location permission
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        setState(() {
          _locationState = _CheckState.error;
          _isLocationOff = true;
        });
        _handleFailure();
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          setState(() {
            _locationState = _CheckState.error;
            _isLocationOff = true;
          });
          _handleFailure();
          return;
        }
      }
      if (permission == LocationPermission.deniedForever) {
        setState(() {
          _locationState = _CheckState.error;
          _isLocationOff = true;
        });
        _handleFailure();
        return;
      }

      // Check for GPS spoofing / mock location
      bool isMock = false;
      try {
        await Geolocator.getLocationAccuracy();
        final testPosition = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
          ),
        );
        isMock = testPosition.isMocked;
      } catch (_) {}

      if (isMock) {
        debugPrint('[PRECHECK] Mock location detected — rejecting');
        if (mounted) {
          setState(() {
            _locationState = _CheckState.error;
            _isMockLocation = true;
          });
          _handleFailure();
        }
        return;
      }

      final Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      final double distance = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        campusLat,
        campusLng,
      );

      debugPrint(
        '[PRECHECK] Distance from campus: ${distance.toStringAsFixed(1)}m, radius: ${campusRadius}m',
      );

      if (distance > campusRadius) {
        setState(() => _locationState = _CheckState.error);
        _handleFailure();
        return;
      }

      setState(() => _locationState = _CheckState.success);
    } catch (e) {
      debugPrint('[PRECHECK] Location check error: $e');
      setState(() => _locationState = _CheckState.error);
      _handleFailure();
      return;
    }

    // ── Both passed — navigate to QR scanner ────────────────────
    await Future.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;

    final DateTime? endTime =
        ModalRoute.of(context)?.settings.arguments as DateTime?;
    Navigator.of(
      context,
    ).pushReplacementNamed('/qr-scanner', arguments: endTime);
  }

  void _handleFailure() {
    setState(() {
      _hasFailed = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(''),
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 12.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // ── Hero Icon Badge ─────────────────────────────────────
                FadeSlideY(
                  delay: const Duration(milliseconds: 80),
                  child: Container(
                    width: 92,
                    height: 92,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isDark
                          ? AppStyles.primaryBlue.withValues(alpha: 0.15)
                          : const Color(0xFFEFF6FF),
                      border: Border.all(
                        color: AppStyles.primaryBlue.withValues(
                          alpha: isDark ? 0.25 : 0.12,
                        ),
                        width: 2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: AppStyles.primaryBlue.withValues(
                            alpha: isDark ? 0.2 : 0.08,
                          ),
                          blurRadius: 20,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Center(
                      child: Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isDark
                              ? AppStyles.primaryBlue.withValues(alpha: 0.25)
                              : Colors.white,
                          boxShadow: isDark
                              ? null
                              : [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.04),
                                    blurRadius: 8,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                        ),
                        child: const Icon(
                          Icons.qr_code_scanner_rounded,
                          size: 32,
                          color: AppStyles.primaryBlue,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 18),

                // ── Heading & Subtitle ──────────────────────────────────
                FadeSlideY(
                  delay: const Duration(milliseconds: 150),
                  child: Text(
                    'Verifying Eligibility',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.4,
                      color:
                          theme.textTheme.displayLarge?.color ??
                          AppStyles.textDark,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                FadeSlideY(
                  delay: const Duration(milliseconds: 220),
                  child: Text(
                    'Checking attendance status and campus location',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      color: isDark ? Colors.grey.shade400 : AppStyles.textGray,
                      height: 1.4,
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                // ── Step Indicator ──────────────────────────────────────
                FadeSlideY(
                  delay: const Duration(milliseconds: 280),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.04)
                          : Colors.black.withValues(alpha: 0.02),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _StepDot(
                          label: 'Attendance',
                          isDone: _attendanceState == _CheckState.success,
                          isActive: _attendanceState == _CheckState.checking,
                          isFailed: _attendanceState == _CheckState.error,
                        ),
                        const SizedBox(width: 8),
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 400),
                          curve: Curves.easeInOutCubic,
                          width: 32,
                          height: 2,
                          decoration: BoxDecoration(
                            color: _attendanceState == _CheckState.success
                                ? AppStyles.successGreen
                                : isDark
                                ? Colors.white.withValues(alpha: 0.12)
                                : Colors.black.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _StepDot(
                          label: 'Location',
                          isDone: _locationState == _CheckState.success,
                          isActive: _locationState == _CheckState.checking,
                          isFailed: _locationState == _CheckState.error,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 22),

                // ── Check Rows ──────────────────────────────────────────
                FadeSlideY(
                  delay: const Duration(milliseconds: 340),
                  child: _CheckRow(
                    title: 'College Attendance',
                    subtitleChecking: 'Verifying minimum attendance...',
                    subtitleSuccess: 'Daily attendance marked — verified',
                    subtitleError: 'Mark your daily face attendance first',
                    icon: Icons.checklist_rounded,
                    state: _attendanceState,
                    isDark: isDark,
                  ),
                ),
                const SizedBox(height: 12),
                if (_locationState != _CheckState.pending)
                  FadeSlideY(
                    delay: const Duration(milliseconds: 100),
                    child: _CheckRow(
                      title: 'Campus Location',
                      subtitleChecking: 'Verifying your location...',
                      subtitleSuccess: 'Location verified — inside campus',
                      subtitleError: _isLocationOff
                          ? 'Location is turned off — please enable it'
                          : _isMockLocation
                          ? 'GPS spoofing detected — use real location'
                          : 'You are outside the campus boundary',
                      icon: Icons.location_on_rounded,
                      state: _locationState,
                      isDark: isDark,
                    ),
                  ),

                // ── Failure State (Concise, Soft, Calm) ─────────────────
                if (_hasFailed) ...[
                  const SizedBox(height: 20),
                  FadeSlideY(
                    delay: const Duration(milliseconds: 150),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: isDark
                            ? AppStyles.errorRed.withValues(alpha: 0.1)
                            : const Color(0xFFFEF2F2),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: AppStyles.errorRed.withValues(
                            alpha: isDark ? 0.25 : 0.18,
                          ),
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: AppStyles.errorRed.withValues(alpha: 0.12),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.info_outline_rounded,
                              color: AppStyles.errorRed,
                              size: 18,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'You are not eligible to scan right now. Please complete the checks above.',
                              style: TextStyle(
                                fontSize: 13,
                                color: isDark
                                    ? Colors.red.shade200
                                    : const Color(0xFF991B1B),
                                height: 1.35,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  FadeSlideY(
                    delay: const Duration(milliseconds: 250),
                    child: SizedBox(
                      width: double.infinity,
                      child: AnimatedButton(
                        onPressed: () => Navigator.of(
                          context,
                        ).pushReplacementNamed('/dashboard'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppStyles.primaryBlue,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 15),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          elevation: 0,
                        ),
                        child: const Text(
                          'Go Back',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  final String title;
  final String subtitleChecking;
  final String subtitleSuccess;
  final String subtitleError;
  final IconData icon;
  final _CheckState state;
  final bool isDark;

  const _CheckRow({
    required this.title,
    required this.subtitleChecking,
    required this.subtitleSuccess,
    required this.subtitleError,
    required this.icon,
    required this.state,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    Color bgColor;
    Color borderColor;
    Color iconColor;
    Color iconBgColor;
    String currentSubtitle;

    switch (state) {
      case _CheckState.pending:
      case _CheckState.checking:
        bgColor = isDark
            ? Colors.white.withValues(alpha: 0.04)
            : Colors.white;
        borderColor = isDark
            ? Colors.white.withValues(alpha: 0.08)
            : const Color(0xFFE2E8F0);
        iconColor = AppStyles.primaryBlue;
        iconBgColor = AppStyles.primaryBlue.withValues(alpha: 0.1);
        currentSubtitle = subtitleChecking;
        break;
      case _CheckState.success:
        bgColor = isDark
            ? AppStyles.successGreen.withValues(alpha: 0.08)
            : const Color(0xFFF0FDF4);
        borderColor = AppStyles.successGreen.withValues(
          alpha: isDark ? 0.25 : 0.2,
        );
        iconColor = AppStyles.successGreen;
        iconBgColor = AppStyles.successGreen.withValues(alpha: 0.12);
        currentSubtitle = subtitleSuccess;
        break;
      case _CheckState.error:
        bgColor = isDark
            ? AppStyles.errorRed.withValues(alpha: 0.08)
            : const Color(0xFFFEF2F2);
        borderColor = AppStyles.errorRed.withValues(alpha: isDark ? 0.25 : 0.2);
        iconColor = AppStyles.errorRed;
        iconBgColor = AppStyles.errorRed.withValues(alpha: 0.12);
        currentSubtitle = subtitleError;
        break;
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
        boxShadow: isDark
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.03),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: iconBgColor,
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(icon, color: iconColor, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14.5,
                    color:
                        Theme.of(context).textTheme.bodyLarge?.color ??
                        AppStyles.textDark,
                  ),
                ),
                const SizedBox(height: 3),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: Text(
                    currentSubtitle,
                    key: ValueKey<String>(currentSubtitle),
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      color: state == _CheckState.error
                          ? AppStyles.errorRed
                          : isDark
                          ? Colors.grey.shade400
                          : AppStyles.textGray,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 350),
            transitionBuilder: (child, animation) {
              return ScaleTransition(
                scale: animation,
                child: FadeTransition(opacity: animation, child: child),
              );
            },
            child: _buildStatusWidget(),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusWidget() {
    switch (state) {
      case _CheckState.pending:
        return const SizedBox(width: 22, height: 22);
      case _CheckState.checking:
        return const SizedBox(
          key: ValueKey('checking'),
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2.2,
            color: AppStyles.primaryBlue,
          ),
        );
      case _CheckState.success:
        return const Icon(
          Icons.check_circle_rounded,
          key: ValueKey('success'),
          color: AppStyles.successGreen,
          size: 24,
        );
      case _CheckState.error:
        return const Icon(
          Icons.cancel_rounded,
          key: ValueKey('error'),
          color: AppStyles.errorRed,
          size: 24,
        );
    }
  }
}

class _StepDot extends StatelessWidget {
  final String label;
  final bool isDone;
  final bool isActive;
  final bool isFailed;

  const _StepDot({
    required this.label,
    required this.isDone,
    required this.isActive,
    required this.isFailed,
  });

  @override
  Widget build(BuildContext context) {
    Color dotColor;
    Widget dotChild;

    if (isFailed) {
      dotColor = AppStyles.errorRed;
      dotChild = const Icon(Icons.close_rounded, color: Colors.white, size: 11);
    } else if (isDone) {
      dotColor = AppStyles.successGreen;
      dotChild = const Icon(Icons.check_rounded, color: Colors.white, size: 11);
    } else if (isActive) {
      dotColor = AppStyles.primaryBlue;
      dotChild = const SizedBox(
        width: 9,
        height: 9,
        child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white),
      );
    } else {
      dotColor = Colors.grey.shade300;
      dotChild = const SizedBox.shrink();
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeInOut,
          width: 20,
          height: 20,
          decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          child: Center(child: dotChild),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: isDone || isActive ? FontWeight.w700 : FontWeight.w500,
            color: isDone
                ? AppStyles.successGreen
                : isActive
                ? AppStyles.primaryBlue
                : AppStyles.textGray,
          ),
        ),
      ],
    );
  }
}
