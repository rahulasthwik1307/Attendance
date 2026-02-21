import 'package:flutter/material.dart';
import '../utils/app_styles.dart';
import '../widgets/animated_button.dart';
import '../widgets/fade_slide_y.dart';

// ─── Strength levels ─────────────────────────────────────────────────────────
enum _PasswordStrength { empty, weak, medium, strong }

_PasswordStrength _computeStrength(String password) {
  if (password.isEmpty) return _PasswordStrength.empty;
  int score = 0;
  if (password.length >= 8) score++;
  if (RegExp(r'[A-Z]').hasMatch(password) &&
      RegExp(r'[a-z]').hasMatch(password)) {
    score++;
  }
  if (RegExp(r'[0-9]').hasMatch(password)) {
    score++;
  }
  if (RegExp(r'[!@#\$&*~%^()_\-+=\[\]{};:,.<>?/\\|`]').hasMatch(password)) {
    score++;
  }
  if (score <= 1) return _PasswordStrength.weak;
  if (score <= 2) return _PasswordStrength.medium;
  return _PasswordStrength.strong;
}

Color _strengthColor(_PasswordStrength s) {
  switch (s) {
    case _PasswordStrength.weak:
      return AppStyles.errorRed;
    case _PasswordStrength.medium:
      return AppStyles.warningYellow;
    case _PasswordStrength.strong:
      return AppStyles.successGreen;
    case _PasswordStrength.empty:
      return Colors.transparent;
  }
}

String _strengthLabel(_PasswordStrength s) {
  switch (s) {
    case _PasswordStrength.weak:
      return 'Weak';
    case _PasswordStrength.medium:
      return 'Medium';
    case _PasswordStrength.strong:
      return 'Strong';
    case _PasswordStrength.empty:
      return '';
  }
}

// ─── Screen ──────────────────────────────────────────────────────────────────
class SetNewPasswordScreen extends StatefulWidget {
  const SetNewPasswordScreen({super.key});

  @override
  State<SetNewPasswordScreen> createState() => _SetNewPasswordScreenState();
}

class _SetNewPasswordScreenState extends State<SetNewPasswordScreen> {
  final _newPwController = TextEditingController();
  final _confirmPwController = TextEditingController();

  bool _obscureNew = true;
  bool _obscureConfirm = true;

  _PasswordStrength _strength = _PasswordStrength.empty;
  bool _isMatch = true; // true = no error shown yet
  bool _confirmTouched = false;

  bool get _canSubmit =>
      _newPwController.text.isNotEmpty &&
      _confirmPwController.text.isNotEmpty &&
      _newPwController.text == _confirmPwController.text &&
      _strength != _PasswordStrength.weak;

  void _onNewPasswordChanged(String value) {
    setState(() {
      _strength = _computeStrength(value);
      if (_confirmTouched) {
        _isMatch = value == _confirmPwController.text;
      }
    });
  }

  void _onConfirmPasswordChanged(String value) {
    setState(() {
      _confirmTouched = true;
      _isMatch = _newPwController.text == value;
    });
  }

  void _onSave() {
    if (!_canSubmit) return;
    Navigator.of(context).pushReplacementNamed('/home');
  }

  // ── Building ──────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _newPwController.dispose();
    _confirmPwController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final headingColor = isDark
        ? Colors.white.withValues(alpha: 0.95)
        : AppStyles.textDark;
    final subtitleColor = isDark ? Colors.grey.shade400 : AppStyles.textGray;
    final surfaceColor = isDark ? AppStyles.surfaceDark : Colors.white;
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.black.withValues(alpha: 0.09);

    final strengthFraction = switch (_strength) {
      _PasswordStrength.empty => 0.0,
      _PasswordStrength.weak => 0.3,
      _PasswordStrength.medium => 0.65,
      _PasswordStrength.strong => 1.0,
    };

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back_ios_new_rounded,
            size: 20,
            color: isDark ? Colors.white : AppStyles.textDark,
          ),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(flex: 1),

              // ── Icon Hero ───────────────────────────────────────────
              FadeSlideY(
                delay: const Duration(milliseconds: 60),
                child: Center(
                  child: Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: theme.primaryColor.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.lock_reset_rounded,
                      size: 36,
                      color: theme.primaryColor,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // ── Title ─────────────────────────────────────────────
              FadeSlideY(
                delay: const Duration(milliseconds: 130),
                child: Text(
                  'Set a New Password',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    height: 1.2,
                    color: headingColor,
                    letterSpacing: -0.4,
                  ),
                ),
              ),
              const SizedBox(height: 8),

              // ── Subtitle ──────────────────────────────────────────
              FadeSlideY(
                delay: const Duration(milliseconds: 200),
                child: Text(
                  'Choose something strong and memorable.\nYou\'ve got this!',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.55,
                    color: subtitleColor,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ),

              const Spacer(flex: 1),

              // ── New Password Field ────────────────────────────────
              FadeSlideY(
                delay: const Duration(milliseconds: 280),
                child: _buildPasswordField(
                  controller: _newPwController,
                  label: 'New Password',
                  hint: 'Enter new password',
                  obscure: _obscureNew,
                  onToggle: () => setState(() => _obscureNew = !_obscureNew),
                  onChanged: _onNewPasswordChanged,
                  surfaceColor: surfaceColor,
                  borderColor: borderColor,
                  primaryColor: theme.primaryColor,
                  isDark: isDark,
                  isError: false,
                ),
              ),
              const SizedBox(height: 10),

              // ── Strength Indicator ────────────────────────────────
              FadeSlideY(
                delay: const Duration(milliseconds: 320),
                child: _StrengthBar(
                  fraction: strengthFraction,
                  strength: _strength,
                ),
              ),

              const SizedBox(height: 18),

              // ── Confirm Password Field ────────────────────────────
              FadeSlideY(
                delay: const Duration(milliseconds: 380),
                child: _buildPasswordField(
                  controller: _confirmPwController,
                  label: 'Confirm Password',
                  hint: 'Re-enter your password',
                  obscure: _obscureConfirm,
                  onToggle: () =>
                      setState(() => _obscureConfirm = !_obscureConfirm),
                  onChanged: _onConfirmPasswordChanged,
                  surfaceColor: surfaceColor,
                  borderColor: borderColor,
                  primaryColor: theme.primaryColor,
                  isDark: isDark,
                  isError: _confirmTouched && !_isMatch,
                ),
              ),

              // ── Match Status Row ──────────────────────────────────
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                child: _confirmTouched
                    ? Padding(
                        key: ValueKey(_isMatch),
                        padding: const EdgeInsets.only(top: 8.0, left: 4),
                        child: Row(
                          children: [
                            Icon(
                              _isMatch
                                  ? Icons.check_circle_rounded
                                  : Icons.cancel_rounded,
                              size: 15,
                              color: _isMatch
                                  ? AppStyles.successGreen
                                  : AppStyles.errorRed,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _isMatch
                                  ? 'Passwords match'
                                  : 'Passwords don\'t match',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: _isMatch
                                    ? AppStyles.successGreen
                                    : AppStyles.errorRed,
                              ),
                            ),
                          ],
                        ),
                      )
                    : const SizedBox.shrink(key: ValueKey('empty')),
              ),

              const Spacer(flex: 2),

              // ── Save Password CTA ─────────────────────────────────
              FadeSlideY(
                delay: const Duration(milliseconds: 440),
                child: Opacity(
                  opacity: _canSubmit ? 1.0 : 0.45,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: _canSubmit
                          ? [
                              BoxShadow(
                                color: theme.primaryColor.withValues(
                                  alpha: 0.30,
                                ),
                                blurRadius: 16,
                                offset: const Offset(0, 6),
                              ),
                            ]
                          : [],
                    ),
                    child: AnimatedButton(
                      onPressed: _canSubmit ? _onSave : () {},
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        elevation: 0,
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.save_rounded, size: 18),
                          SizedBox(width: 8),
                          Text('Save Password', style: TextStyle(fontSize: 16)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Password Text Field helper ──────────────────────────────────────────────
Widget _buildPasswordField({
  required TextEditingController controller,
  required String label,
  required String hint,
  required bool obscure,
  required VoidCallback onToggle,
  required ValueChanged<String> onChanged,
  required Color surfaceColor,
  required Color borderColor,
  required Color primaryColor,
  required bool isDark,
  required bool isError,
}) {
  final errorColor = AppStyles.errorRed;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: isDark ? Colors.grey.shade300 : AppStyles.textDark,
          letterSpacing: 0.1,
        ),
      ),
      const SizedBox(height: 8),
      AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color: surfaceColor,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(
            color: isError ? errorColor : borderColor,
            width: isError ? 1.8 : 1.2,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.04),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: TextField(
          controller: controller,
          obscureText: obscure,
          onChanged: onChanged,
          style: TextStyle(
            fontSize: 15,
            color: isDark
                ? Colors.white.withValues(alpha: 0.9)
                : AppStyles.textDark,
          ),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(
              color: isDark ? Colors.grey.shade600 : Colors.grey.shade400,
              fontSize: 14,
            ),
            prefixIcon: Icon(
              Icons.lock_outline_rounded,
              size: 20,
              color: isError
                  ? errorColor
                  : (isDark ? Colors.grey.shade500 : Colors.grey.shade400),
            ),
            suffixIcon: IconButton(
              onPressed: onToggle,
              icon: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: Icon(
                  obscure
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  key: ValueKey(obscure),
                  size: 20,
                  color: isDark ? Colors.grey.shade500 : Colors.grey.shade400,
                ),
              ),
            ),
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 16,
            ),
          ),
        ),
      ),
    ],
  );
}

// ── Animated Strength Bar ───────────────────────────────────────────────────
class _StrengthBar extends StatelessWidget {
  final double fraction; // 0.0 – 1.0
  final _PasswordStrength strength;

  const _StrengthBar({required this.fraction, required this.strength});

  @override
  Widget build(BuildContext context) {
    final color = _strengthColor(strength);
    final label = _strengthLabel(strength);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final trackColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.06);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Track + animated fill
        LayoutBuilder(
          builder: (context, constraints) {
            return Stack(
              children: [
                // Background track
                Container(
                  height: 5,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: trackColor,
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                // Animated fill
                AnimatedContainer(
                  duration: const Duration(milliseconds: 350),
                  curve: Curves.easeInOut,
                  height: 5,
                  width: constraints.maxWidth * fraction,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: fraction > 0
                        ? [
                            BoxShadow(
                              color: color.withValues(alpha: 0.45),
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                            ),
                          ]
                        : [],
                  ),
                ),
              ],
            );
          },
        ),
        // Label
        if (label.isNotEmpty) ...[
          const SizedBox(height: 6),
          AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 250),
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: color,
              letterSpacing: 0.3,
            ),
            child: Text(label),
          ),
        ],
      ],
    );
  }
}
