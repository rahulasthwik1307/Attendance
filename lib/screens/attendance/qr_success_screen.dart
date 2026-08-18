import 'package:flutter/material.dart';
import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../utils/app_styles.dart';
import '../../widgets/animated_button.dart';
import '../../widgets/fade_slide_y.dart';

class QrSuccessScreen extends StatefulWidget {
  const QrSuccessScreen({super.key});

  @override
  State<QrSuccessScreen> createState() => _QrSuccessScreenState();
}

class _QrSuccessScreenState extends State<QrSuccessScreen>
    with TickerProviderStateMixin {
  late AnimationController _checkController;
  late Animation<double> _scaleAnim;
  late AnimationController _rippleController;
  Timer? _timer;

  // Progress line instead of "Redirecting in X seconds..."
  static const int _redirectDuration = 3;
  double _progress = 0.0;
  int _elapsed = 0;

  String _subjectName = '';
  String _periodInfo = '';
  String _markedAt = '';

  @override
  void initState() {
    super.initState();

    _checkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _scaleAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _checkController, curve: Curves.elasticOut),
    );

    // Single radial glow pulse
    _rippleController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..forward();

    _checkController.forward();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fetchSuccessInfo();
    });

    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _elapsed++;
      setState(() => _progress = _elapsed / _redirectDuration);
      if (_elapsed >= _redirectDuration) {
        _goToDashboard();
      }
    });
  }

  Future<void> _fetchSuccessInfo() async {
    try {
      final args = ModalRoute.of(context)?.settings.arguments;
      String? sessionId;
      if (args is Map) sessionId = args['session_id'] as String?;
      if (sessionId == null) return;

      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) return;

      final results = await Future.wait([
        Supabase.instance.client
            .from('attendance_sessions')
            .select('subject_id, period_id')
            .eq('id', sessionId)
            .maybeSingle(),
        Supabase.instance.client
            .from('period_attendance')
            .select('scanned_at')
            .eq('session_id', sessionId)
            .eq('student_id', user.id)
            .maybeSingle(),
      ]);

      final sessionData = results[0];
      final attendanceData = results[1];

      if (sessionData == null) return;

      final subjectResult = await Supabase.instance.client
          .from('subjects')
          .select('name')
          .eq('id', sessionData['subject_id'])
          .maybeSingle();

      final periodResult = await Supabase.instance.client
          .from('periods')
          .select('period_number')
          .eq('id', sessionData['period_id'])
          .maybeSingle();

      String getOrdinal(int n) {
        if (n >= 11 && n <= 13) return 'th';
        switch (n % 10) {
          case 1:
            return 'st';
          case 2:
            return 'nd';
          case 3:
            return 'rd';
          default:
            return 'th';
        }
      }

      String markedAtFormatted = '';
      if (attendanceData?['scanned_at'] != null) {
        final dt = DateTime.parse(attendanceData!['scanned_at']).toLocal();
        final hh = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
        final mm = dt.minute.toString().padLeft(2, '0');
        final ampm = dt.hour >= 12 ? 'PM' : 'AM';
        markedAtFormatted = '$hh:$mm $ampm';
      }

      final int periodNum = periodResult?['period_number'] as int? ?? 1;

      if (mounted) {
        setState(() {
          _subjectName = subjectResult?['name'] as String? ?? 'Unknown';
          _periodInfo = '$periodNum${getOrdinal(periodNum)} Period';
          _markedAt = markedAtFormatted;
        });
      }
    } catch (e) {
      debugPrint('[QR_SUCCESS] Failed to fetch info: $e');
    }
  }

  void _goToDashboard() {
    _timer?.cancel();
    if (!mounted) return;
    Navigator.of(context).pushReplacementNamed('/dashboard');
  }

  @override
  void dispose() {
    _checkController.dispose();
    _rippleController.dispose();
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // ── Animated checkmark with radial glow ────────────
                  FadeSlideY(
                    delay: const Duration(milliseconds: 0),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        // Single radial glow pulse
                        AnimatedBuilder(
                          animation: _rippleController,
                          builder: (context, child) {
                            return Container(
                              width: 120 + (_rippleController.value * 36),
                              height: 120 + (_rippleController.value * 36),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: AppStyles.successGreen.withValues(
                                  alpha: (1 - _rippleController.value) * 0.15,
                                ),
                              ),
                            );
                          },
                        ),
                        ScaleTransition(
                          scale: _scaleAnim,
                          child: Container(
                            width: 88,
                            height: 88,
                            decoration: BoxDecoration(
                              color: isDark
                                  ? AppStyles.successGreen.withValues(
                                      alpha: 0.15,
                                    )
                                  : const Color(0xFFDCFCE7),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: AppStyles.successGreen.withValues(
                                  alpha: isDark ? 0.3 : 0.2,
                                ),
                                width: 2,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: AppStyles.successGreen.withValues(
                                    alpha: isDark ? 0.25 : 0.15,
                                  ),
                                  blurRadius: 20,
                                  offset: const Offset(0, 8),
                                ),
                              ],
                            ),
                            child: Center(
                              child: Container(
                                width: 56,
                                height: 56,
                                decoration: const BoxDecoration(
                                  color: AppStyles.successGreen,
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.check_rounded,
                                  color: Colors.white,
                                  size: 36,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // ── Title ──────────────────────────────────────────
                  FadeSlideY(
                    delay: const Duration(milliseconds: 200),
                    child: Text(
                      'Attendance Marked!',
                      style: TextStyle(
                        fontSize: 24,
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
                    delay: const Duration(milliseconds: 280),
                    child: Text(
                      'Period attendance successfully recorded',
                      style: TextStyle(
                        fontSize: 14,
                        color: isDark
                            ? Colors.grey.shade400
                            : AppStyles.textGray,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // ── Details card ───────────────────────────────────
                  FadeSlideY(
                    delay: const Duration(milliseconds: 400),
                    child: Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.05)
                            : Colors.white,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.08)
                              : const Color(0xFFE2E8F0),
                        ),
                        boxShadow: isDark
                            ? null
                            : [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.04),
                                  blurRadius: 12,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                      ),
                      child: Column(
                        children: [
                          _DetailRow(
                            icon: Icons.menu_book_rounded,
                            iconColor: AppStyles.primaryBlue,
                            label: 'Subject',
                            value: _subjectName.isEmpty ? '...' : _subjectName,
                          ),
                          _divider(isDark),
                          _DetailRow(
                            icon: Icons.schedule_rounded,
                            iconColor: Colors.orange.shade600,
                            label: 'Period',
                            value: _periodInfo.isEmpty ? '...' : _periodInfo,
                          ),
                          _divider(isDark),
                          _DetailRow(
                            icon: Icons.access_time_filled_rounded,
                            iconColor: Colors.purple.shade400,
                            label: 'Marked At',
                            value: _markedAt.isEmpty ? '...' : _markedAt,
                          ),
                          _divider(isDark),
                          _DetailRow(
                            icon: Icons.verified_user_rounded,
                            iconColor: AppStyles.successGreen,
                            label: 'Face Verified',
                            value: 'Confirmed ✓',
                            valueColor: AppStyles.successGreen,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // ── Thin progress line (replaces countdown text) ───
                  FadeSlideY(
                    delay: const Duration(milliseconds: 550),
                    child: Column(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: SizedBox(
                            height: 3.5,
                            width: double.infinity,
                            child: LinearProgressIndicator(
                              value: _progress,
                              backgroundColor: isDark
                                  ? Colors.white.withValues(alpha: 0.08)
                                  : const Color(0xFFE2E8F0),
                              valueColor: const AlwaysStoppedAnimation<Color>(
                                AppStyles.primaryBlue,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Redirecting to dashboard…',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: isDark
                                ? Colors.grey.shade400
                                : AppStyles.textGray,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),

                  // ── Dashboard button with elevation & bounce ───────
                  FadeSlideY(
                    delay: const Duration(milliseconds: 650),
                    child: SizedBox(
                      width: double.infinity,
                      child: AnimatedButton(
                        onPressed: _goToDashboard,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppStyles.primaryBlue,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          elevation: 0,
                        ),
                        child: const Text(
                          'Go to Dashboard',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
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

  Widget _divider(bool isDark) {
    return Divider(
      height: 1,
      thickness: 1,
      indent: 54,
      color: isDark
          ? Colors.white.withValues(alpha: 0.06)
          : const Color(0xFFF1F5F9),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final String value;
  final Color? valueColor;

  const _DetailRow({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icon, color: iconColor, size: 17),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 95,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                color: AppStyles.textGray,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: valueColor ??
                    (theme.textTheme.bodyLarge?.color ?? AppStyles.textDark),
              ),
              textAlign: TextAlign.end,
              softWrap: true,
            ),
          ),
        ],
      ),
    );
  }
}
