import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/auth_service.dart';
import '../../utils/app_styles.dart';
import '../../utils/auth_flow_state.dart';
import '../../widgets/fade_slide_y.dart';

class RegistrationSuccessScreen extends StatefulWidget {
  const RegistrationSuccessScreen({super.key});

  @override
  State<RegistrationSuccessScreen> createState() =>
      _RegistrationSuccessScreenState();
}

class _RegistrationSuccessScreenState extends State<RegistrationSuccessScreen>
    with TickerProviderStateMixin {
  late AnimationController _checkController;
  late Animation<double> _scaleAnimation;
  late AnimationController _rippleController;

  bool _isLeaveDialogShowing = false;
  bool _isExiting = false;

  @override
  void initState() {
    super.initState();

    _checkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );

    _scaleAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _checkController, curve: Curves.elasticOut),
    );

    _rippleController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    _checkController.forward();
    // No timer — student stays here until they manually check status
  }

  Future<void> _checkApprovalStatus() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;

    final data = await Supabase.instance.client
        .from('students')
        .select('is_approved, is_rejected')
        .eq('id', user.id)
        .maybeSingle();

    if (!mounted) return;

    if (data == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not fetch status. Please try again.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final bool isApproved = data['is_approved'] == true;
    final bool isRejected = data['is_rejected'] == true;

    if (isApproved) {
      AuthFlowState.instance.passwordSet = true;
      debugPrint(
        '[REG_SUCCESS] Teacher approved — navigating to calibration verification',
      );
      Navigator.of(
        context,
      ).pushNamedAndRemoveUntil('/face_calibration_verify', (route) => false);
    } else if (isRejected) {
      // Show rejection dialog then redirect to home
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: const Text(
            'Registration Rejected',
            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red),
          ),
          content: const Text(
            'Your face registration was rejected by your teacher. Please re-register your face.',
            style: TextStyle(fontSize: 14, height: 1.5),
          ),
          actions: [
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppStyles.primaryBlue,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      // Reset auth flow state and go to home
      AuthFlowState.instance.faceRegistered = false;
      AuthFlowState.instance.passwordSet = true;
      Navigator.of(context).pushNamedAndRemoveUntil('/home', (route) => false);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Not approved yet. Please wait for your teacher.'),
          backgroundColor: Colors.orange,
        ),
      );
    }
  }

  // ── Leave confirmation dialog & exit handler ─────────────────────────────
  Future<void> _showLeaveConfirmationDialog() async {
    if (_isLeaveDialogShowing || _isExiting || !mounted) return;
    _isLeaveDialogShowing = true;

    final shouldExit = await showGeneralDialog<bool>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Dismiss Leave Dialog',
      barrierColor: Colors.black.withValues(alpha: 0.54),
      transitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (dialogContext, anim1, anim2) {
        return _buildLeaveConfirmationDialog(dialogContext);
      },
      transitionBuilder: (dialogContext, anim1, anim2, child) {
        final curvedValue = Curves.easeOutCubic.transform(anim1.value);
        return BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: 4.0 * anim1.value,
            sigmaY: 4.0 * anim1.value,
          ),
          child: Opacity(
            opacity: anim1.value.clamp(0.0, 1.0),
            child: Transform.scale(
              scale: 0.94 + (0.06 * curvedValue),
              child: child,
            ),
          ),
        );
      },
    );

    _isLeaveDialogShowing = false;

    if (shouldExit == true && mounted) {
      await _handleExit();
    }
  }

  Future<void> _handleExit() async {
    if (_isExiting) return;
    _isExiting = true;
    try {
      await AuthService().signOut();
    } catch (e) {
      debugPrint('[REG_SUCCESS] signOut error (non-fatal): $e');
    }
    if (!mounted) return;
    Navigator.of(
      context,
    ).pushNamedAndRemoveUntil('/sign_in', (route) => false);
  }

  Widget _buildLeaveConfirmationDialog(BuildContext dialogContext) {
    return Dialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 16,
      shadowColor: Colors.black.withValues(alpha: 0.2),
      insetPadding: const EdgeInsets.symmetric(horizontal: 28),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(
          color: const Color(0xFFE2E8F0).withValues(alpha: 0.9),
          width: 1,
        ),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Schedule / Info Badge Icon
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF7ED),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: const Color(0xFFFFEDD5),
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFEA580C).withValues(alpha: 0.12),
                      blurRadius: 14,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: const Center(
                  child: Icon(
                    Icons.schedule_rounded,
                    color: Color(0xFFEA580C),
                    size: 30,
                  ),
                ),
              ),
              const SizedBox(height: 18),

              // Title
              const Text(
                'Leave registration?',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF0F172A),
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 10),

              // Message
              const Text(
                'Your registration is still waiting for teacher approval. You can return later and check your approval status.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF475569),
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 24),

              // Actions: Exit / Stay
              Row(
                children: [
                  // Exit Action
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(dialogContext).pop(true),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF64748B),
                        side: const BorderSide(
                          color: Color(0xFFCBD5E1),
                          width: 1.2,
                        ),
                        backgroundColor: const Color(0xFFF8FAFC),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        elevation: 0,
                      ),
                      child: const Text(
                        'Exit',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF64748B),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),

                  // Primary Stay Action
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => Navigator.of(dialogContext).pop(false),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppStyles.primaryBlue,
                        foregroundColor: Colors.white,
                        elevation: 2,
                        shadowColor:
                            AppStyles.primaryBlue.withValues(alpha: 0.35),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 13),
                      ),
                      child: const Text(
                        'Stay',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          letterSpacing: 0.1,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _checkController.dispose();
    _rippleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _showLeaveConfirmationDialog();
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Stack(
                alignment: Alignment.center,
                children: [
                  // Ripple effect
                  AnimatedBuilder(
                    animation: _rippleController,
                    builder: (context, child) {
                      return Container(
                        width: 150 + (_rippleController.value * 50),
                        height: 150 + (_rippleController.value * 50),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppStyles.successGreen.withValues(
                            alpha: 1 - _rippleController.value,
                          ),
                        ),
                      );
                    },
                  ),
                  ScaleTransition(
                    scale: _scaleAnimation,
                    child: Container(
                      padding: const EdgeInsets.all(24),
                      decoration: const BoxDecoration(
                        color: AppStyles.successGreen,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.check_rounded,
                        size: 60,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 48),
              const FadeSlideY(
                delay: Duration(milliseconds: 300),
                child: Text(
                  'Registration Submitted',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: AppStyles.textDark,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const FadeSlideY(
                delay: Duration(milliseconds: 400),
                child: Text(
                  'Awaiting teacher approval',
                  style: TextStyle(fontSize: 16, color: AppStyles.textGray),
                ),
              ),
              const SizedBox(height: 32),
              FadeSlideY(
                delay: const Duration(milliseconds: 500),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 48),
                  child: ElevatedButton(
                    onPressed: _checkApprovalStatus,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppStyles.primaryBlue,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      minimumSize: const Size(double.infinity, 48),
                    ),
                    child: const Text(
                      'Check Approval Status',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              FadeSlideY(
                delay: const Duration(milliseconds: 600),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 48),
                  child: OutlinedButton(
                    onPressed: _showLeaveConfirmationDialog,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF334155),
                      backgroundColor: const Color(0xFFF8FAFC),
                      side: BorderSide(
                        color: const Color(0xFFCBD5E1).withValues(alpha: 0.9),
                        width: 1.4,
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      minimumSize: const Size(double.infinity, 48),
                      elevation: 0,
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.logout_rounded,
                          size: 18,
                          color: Color(0xFF64748B),
                        ),
                        SizedBox(width: 8),
                        Text(
                          'Exit',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF334155),
                            letterSpacing: 0.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
