import 'package:flutter/material.dart';
import 'dart:async';
import '../../utils/app_styles.dart';
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

  @override
  void initState() {
    super.initState();
    _runChecks();
  }

  Future<void> _runChecks() async {
    // Check 1: Attendance
    await Future.delayed(const Duration(milliseconds: 1200));
    if (!mounted) return;

    // For demo purposes, we assume success. To test failure, change to _CheckState.error
    setState(() {
      _attendanceState = _CheckState.success;
      _locationState = _CheckState.checking;
    });

    if (_attendanceState == _CheckState.error) {
      _handleFailure();
      return;
    }

    // Check 2: Location
    await Future.delayed(const Duration(milliseconds: 1000));
    if (!mounted) return;

    setState(() {
      _locationState = _CheckState.success;
    });

    if (_locationState == _CheckState.error) {
      _handleFailure();
      return;
    }

    // Both passed
    await Future.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;

    // Navigate to scanner
    Navigator.of(context).pushReplacementNamed('/qr-scanner');
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
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 20.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FadeSlideY(
                delay: const Duration(milliseconds: 100),
                child: Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: AppStyles.primaryBlue.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.qr_code_scanner_rounded,
                    size: 64,
                    color: AppStyles.primaryBlue,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              FadeSlideY(
                delay: const Duration(milliseconds: 200),
                child: Text(
                  'Verifying Eligibility',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color:
                        theme.textTheme.displayLarge?.color ??
                        AppStyles.textDark,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              FadeSlideY(
                delay: const Duration(milliseconds: 300),
                child: const Text(
                  'Please wait while we check the requirements',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 15, color: AppStyles.textGray),
                ),
              ),
              const SizedBox(height: 24),

              // ── Step indicator ──────────────────────────────────
              FadeSlideY(
                delay: const Duration(milliseconds: 350),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _StepDot(
                      label: 'Attendance',
                      isDone: _attendanceState == _CheckState.success,
                      isActive: _attendanceState == _CheckState.checking,
                      isFailed: _attendanceState == _CheckState.error,
                    ),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 500),
                      curve: Curves.easeOutCubic,
                      width: _attendanceState == _CheckState.success ? 40 : 0,
                      height: 1.5,
                      decoration: BoxDecoration(
                        color: _attendanceState == _CheckState.success
                            ? AppStyles.successGreen.withValues(alpha: 0.5)
                            : Colors.black.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                    _StepDot(
                      label: 'Location',
                      isDone: _locationState == _CheckState.success,
                      isActive: _locationState == _CheckState.checking,
                      isFailed: _locationState == _CheckState.error,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 28),

              FadeSlideY(
                delay: const Duration(milliseconds: 400),
                child: _CheckRow(
                  title: 'College Attendance',
                  subtitleChecking: 'Verifying minimum attendance...',
                  subtitleSuccess: 'Attendance marked — verified',
                  subtitleError: 'Attendance requirement not met',
                  icon: Icons.checklist_rounded,
                  state: _attendanceState,
                  isDark: isDark,
                ),
              ),
              const SizedBox(height: 16),
              if (_locationState != _CheckState.pending)
                FadeSlideY(
                  delay: const Duration(milliseconds: 100),
                  child: _CheckRow(
                    title: 'Campus Location',
                    subtitleChecking: 'Verifying your location...',
                    subtitleSuccess: 'Location verified — inside campus',
                    subtitleError: 'You are outside the campus boundary',
                    icon: Icons.location_on_rounded,
                    state: _locationState,
                    isDark: isDark,
                  ),
                ),

              if (_hasFailed) ...[
                const SizedBox(height: 32),
                FadeSlideY(
                  delay: const Duration(milliseconds: 200),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppStyles.errorRed.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: AppStyles.errorRed.withValues(alpha: 0.3),
                      ),
                    ),
                    child: const Column(
                      children: [
                        Icon(
                          Icons.error_outline_rounded,
                          color: AppStyles.errorRed,
                          size: 32,
                        ),
                        SizedBox(height: 12),
                        Text(
                          'Verification Failed',
                          style: TextStyle(
                            color: AppStyles.errorRed,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        SizedBox(height: 8),
                        Text(
                          'You are not eligible to scan the QR code at this time. Please contact administration if you believe this is an error.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: AppStyles.errorRed,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                FadeSlideY(
                  delay: const Duration(milliseconds: 300),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppStyles.errorRed,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        elevation: 0,
                      ),
                      child: const Text(
                        'Go Back',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
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
    String currentSubtitle;

    switch (state) {
      case _CheckState.pending:
      case _CheckState.checking:
        bgColor = isDark
            ? Colors.white.withValues(alpha: 0.05)
            : Colors.black.withValues(alpha: 0.02);
        borderColor = isDark
            ? Colors.white.withValues(alpha: 0.1)
            : Colors.black.withValues(alpha: 0.05);
        iconColor = AppStyles.primaryBlue;
        currentSubtitle = subtitleChecking;
        break;
      case _CheckState.success:
        bgColor = AppStyles.successGreen.withValues(alpha: 0.1);
        borderColor = AppStyles.successGreen.withValues(alpha: 0.3);
        iconColor = AppStyles.successGreen;
        currentSubtitle = subtitleSuccess;
        break;
      case _CheckState.error:
        bgColor = AppStyles.errorRed.withValues(alpha: 0.1);
        borderColor = AppStyles.errorRed.withValues(alpha: 0.3);
        iconColor = AppStyles.errorRed;
        currentSubtitle = subtitleError;
        break;
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: iconColor, size: 20),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                    color:
                        Theme.of(context).textTheme.bodyLarge?.color ??
                        AppStyles.textDark,
                  ),
                ),
                const SizedBox(height: 4),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: Text(
                    currentSubtitle,
                    key: ValueKey<String>(currentSubtitle),
                    style: TextStyle(
                      fontSize: 13,
                      color: state == _CheckState.error
                          ? AppStyles.errorRed
                          : AppStyles.textGray,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 400),
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
        return const SizedBox(width: 24, height: 24);
      case _CheckState.checking:
        return const SizedBox(
          key: ValueKey('checking'),
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            color: AppStyles.primaryBlue,
          ),
        );
      case _CheckState.success:
        return const Icon(
          Icons.check_circle_rounded,
          key: ValueKey('success'),
          color: AppStyles.successGreen,
          size: 28,
        );
      case _CheckState.error:
        return const Icon(
          Icons.cancel_rounded,
          key: ValueKey('error'),
          color: AppStyles.errorRed,
          size: 28,
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
      dotChild = const Icon(Icons.close_rounded, color: Colors.white, size: 12);
    } else if (isDone) {
      dotColor = AppStyles.successGreen;
      dotChild = const Icon(Icons.check_rounded, color: Colors.white, size: 12);
    } else if (isActive) {
      dotColor = AppStyles.primaryBlue;
      dotChild = const SizedBox(
        width: 10,
        height: 10,
        child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white),
      );
    } else {
      dotColor = Colors.grey.shade300;
      dotChild = const SizedBox.shrink();
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeInOut,
          width: 24,
          height: 24,
          decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          child: Center(child: dotChild),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: isDone || isActive ? FontWeight.w600 : FontWeight.w400,
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
