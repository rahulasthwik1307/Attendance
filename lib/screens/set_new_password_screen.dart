import 'package:flutter/material.dart';
import '../utils/app_styles.dart';
import '../widgets/animated_button.dart';
import '../widgets/fade_slide_y.dart';
import '../utils/auth_flow_state.dart';

// ─── Strength helpers ─────────────────────────────────────────────────────────

enum _Strength { empty, weak, medium, strong }

_Strength _computeStrength(String pw) {
  if (pw.isEmpty) return _Strength.empty;
  int score = 0;
  if (pw.length >= 8) score++;
  if (RegExp(r'[A-Z]').hasMatch(pw) && RegExp(r'[a-z]').hasMatch(pw)) score++;
  if (RegExp(r'[0-9]').hasMatch(pw)) score++;
  if (RegExp(r'[!@#\$&*~%^()_\-+=\[\]{};:,.<>?/\\|`]').hasMatch(pw)) score++;
  if (score <= 1) return _Strength.weak;
  if (score <= 2) return _Strength.medium;
  return _Strength.strong;
}

Color _strengthColor(_Strength s) => switch (s) {
  _Strength.weak => AppStyles.errorRed,
  _Strength.medium => AppStyles.warningYellow,
  _Strength.strong => AppStyles.successGreen,
  _Strength.empty => Colors.transparent,
};

String _strengthLabel(_Strength s) => switch (s) {
  _Strength.weak => 'Weak',
  _Strength.medium => 'Medium',
  _Strength.strong => 'Strong',
  _Strength.empty => '',
};

double _strengthFraction(_Strength s) => switch (s) {
  _Strength.empty => 0.0,
  _Strength.weak => 0.30,
  _Strength.medium => 0.65,
  _Strength.strong => 1.0,
};

// ─── Screen ───────────────────────────────────────────────────────────────────

class SetNewPasswordScreen extends StatefulWidget {
  const SetNewPasswordScreen({super.key});

  @override
  State<SetNewPasswordScreen> createState() => _SetNewPasswordScreenState();
}

class _SetNewPasswordScreenState extends State<SetNewPasswordScreen> {
  final _newPwController = TextEditingController();
  final _confirmPwController = TextEditingController();

  final _newPwFieldKey = GlobalKey<_ShakeWidgetState>();
  final _confirmPwFieldKey = GlobalKey<_ShakeWidgetState>();

  bool _obscureNew = true;
  bool _obscureConfirm = true;
  bool _isLoading = false;
  bool _isSuccess = false;

  _Strength _strength = _Strength.empty;
  bool _isMatch = true;
  bool _confirmTouched = false;
  bool _hasTriedSave = false;
  bool _showWeakError = false;

  // Enforce Strong password requirement
  bool get _canSubmit =>
      _newPwController.text.isNotEmpty &&
      _confirmPwController.text.isNotEmpty &&
      _newPwController.text == _confirmPwController.text &&
      _strength == _Strength.strong;

  void _onNewPasswordChanged(String v) => setState(() {
    _hasTriedSave = false;
    _showWeakError = false;
    _strength = _computeStrength(v);
    if (_confirmTouched) _isMatch = v == _confirmPwController.text;
  });

  void _onConfirmPasswordChanged(String v) => setState(() {
    _hasTriedSave = false;
    _confirmTouched = v.isNotEmpty;
    _isMatch = _newPwController.text == v;
  });

  void _onSave() async {
    if (_isLoading || _isSuccess) return;

    if (!_canSubmit) {
      setState(() => _hasTriedSave = true);
      if (_newPwController.text.isEmpty) {
        _newPwFieldKey.currentState?.shake();
      }
      if (_confirmPwController.text.isEmpty || !_isMatch) {
        _confirmPwFieldKey.currentState?.shake();
      }
      if (_newPwController.text.isNotEmpty &&
          _confirmPwController.text.isNotEmpty &&
          _isMatch &&
          _strength != _Strength.strong) {
        _newPwFieldKey.currentState?.shake();
        setState(() => _showWeakError = true);
      }
      return;
    }

    setState(() => _isLoading = true);
    await Future.delayed(const Duration(milliseconds: 800));
    if (!mounted) return;

    setState(() {
      _isLoading = false;
      _isSuccess = true;
    });
    await Future.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;

    AuthFlowState.instance.passwordSet = true;
    if (mounted) {
      if (AuthFlowState.instance.isFirstTimeUser) {
        AuthFlowState.instance.isFirstTimeUser = false;
        Navigator.of(context).pushReplacementNamed('/register');
      } else if (AuthFlowState.instance.faceRegistered) {
        Navigator.of(
          context,
        ).pushReplacementNamed('/password_updated', arguments: 'settings');
      } else {
        Navigator.of(
          context,
        ).pushReplacementNamed('/password_updated', arguments: 'forgot');
      }
    }
  }

  @override
  void dispose() {
    _newPwController.dispose();
    _confirmPwController.dispose();
    super.dispose();
  }

  Widget _buildHeader(
    ThemeData theme,
    Color headingColor,
    Color subtitleColor,
    Color cardColor,
  ) {
    return Column(
      children: [
        FadeSlideY(
          delay: const Duration(milliseconds: 180),
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: theme.primaryColor.withValues(alpha: 0.09),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(
                  Icons.lock_reset_rounded,
                  color: theme.primaryColor,
                  size: 44,
                ),
                Positioned(
                  bottom: 10,
                  right: 10,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: cardColor,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.check_rounded,
                      color: theme.primaryColor,
                      size: 14,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        FadeSlideY(
          delay: const Duration(milliseconds: 260),
          child: Text(
            'Set a New Password',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              color: headingColor,
              height: 1.15,
              letterSpacing: -0.4,
            ),
          ),
        ),
        const SizedBox(height: 8),
        FadeSlideY(
          delay: const Duration(milliseconds: 340),
          child: Text(
            'Choose something strong and memorable.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              height: 1.5,
              color: subtitleColor,
              fontWeight: FontWeight.w400,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFormCard(
    ThemeData theme,
    Color cardColor,
    Color inputFill,
    bool isDark,
  ) {
    return FadeSlideY(
      delay: const Duration(milliseconds: 460),
      child: _PasswordCard(
        cardColor: cardColor,
        inputFill: inputFill,
        isDark: isDark,
        theme: theme,
        newController: _newPwController,
        newFieldKey: _newPwFieldKey,
        obscureNew: _obscureNew,
        onToggleNew: () => setState(() => _obscureNew = !_obscureNew),
        onChangedNew: _onNewPasswordChanged,
        strength: _strength,
        confirmController: _confirmPwController,
        confirmFieldKey: _confirmPwFieldKey,
        obscureConfirm: _obscureConfirm,
        onToggleConfirm: () =>
            setState(() => _obscureConfirm = !_obscureConfirm),
        onChangedConfirm: _onConfirmPasswordChanged,
        confirmTouched: _confirmTouched,
        isMatch: _isMatch,
        canSubmit: _canSubmit,
        isLoading: _isLoading,
        isSuccess: _isSuccess,
        hasTriedSave: _hasTriedSave,
        showWeakError: _showWeakError,
        onSave: _onSave,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final headingColor =
        theme.textTheme.displayLarge?.color ?? AppStyles.textDark;
    final subtitleColor =
        theme.textTheme.bodyMedium?.color ?? AppStyles.textGray;
    final cardColor =
        theme.cardTheme.color ??
        (isDark ? AppStyles.surfaceDark : Colors.white);
    final inputFill = isDark
        ? AppStyles.surfaceDark.withValues(alpha: 0.6)
        : AppStyles.backgroundLight;

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        resizeToAvoidBottomInset: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          automaticallyImplyLeading: false,
        ),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: 24),
                        _buildHeader(
                          theme,
                          headingColor,
                          subtitleColor,
                          cardColor,
                        ),
                        const _KeyboardGap(),
                        _buildFormCard(theme, cardColor, inputFill, isDark),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

// ─── Card containing both password fields ─────────────────────────────────────

class _PasswordCard extends StatelessWidget {
  final Color cardColor;
  final Color inputFill;
  final bool isDark;
  final ThemeData theme;

  final TextEditingController newController;
  final GlobalKey<_ShakeWidgetState> newFieldKey;
  final bool obscureNew;
  final VoidCallback onToggleNew;
  final ValueChanged<String> onChangedNew;
  final _Strength strength;

  final TextEditingController confirmController;
  final GlobalKey<_ShakeWidgetState> confirmFieldKey;
  final bool obscureConfirm;
  final VoidCallback onToggleConfirm;
  final ValueChanged<String> onChangedConfirm;
  final bool confirmTouched;
  final bool isMatch;

  final bool canSubmit;
  final bool isLoading;
  final bool isSuccess;
  final bool hasTriedSave;
  final bool showWeakError;
  final VoidCallback onSave;

  const _PasswordCard({
    required this.cardColor,
    required this.inputFill,
    required this.isDark,
    required this.theme,
    required this.newController,
    required this.newFieldKey,
    required this.obscureNew,
    required this.onToggleNew,
    required this.onChangedNew,
    required this.strength,
    required this.confirmController,
    required this.confirmFieldKey,
    required this.obscureConfirm,
    required this.onToggleConfirm,
    required this.onChangedConfirm,
    required this.confirmTouched,
    required this.isMatch,
    required this.canSubmit,
    required this.isLoading,
    required this.isSuccess,
    required this.hasTriedSave,
    required this.showWeakError,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    // Card shadow matches Activate Account card elevation feel
    final shadowColor = isDark
        ? Colors.black.withValues(alpha: 0.35)
        : Colors.black.withValues(alpha: 0.08);

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: shadowColor,
            blurRadius: 24,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── New Password ──────────────────────────────────────────────
          _ShakeWidget(
            key: newFieldKey,
            child: _CardField(
              controller: newController,
              label: 'New Password',
              hint: '••••••••',
              obscure: obscureNew,
              onToggle: onToggleNew,
              onChanged: onChangedNew,
              fillColor: inputFill,
              isDark: isDark,
              theme: theme,
              isError:
                  hasTriedSave &&
                  strength != _Strength.strong &&
                  newController.text.isNotEmpty,
              hasTriedSave: hasTriedSave,
              emptyError: 'Please enter your password',
            ),
          ),

          const SizedBox(height: 8),

          // ── Strength bar ──────────────────────────────────────────────
          _StrengthBar(strength: strength, pwLength: newController.text.length),

          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            child: showWeakError
                ? const Text(
                    'Make your password stronger to continue',
                    style: TextStyle(
                      color: AppStyles.errorRed,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  )
                : const SizedBox.shrink(),
          ),

          const SizedBox(height: 18),

          // ── Confirm Password ──────────────────────────────────────────
          _ShakeWidget(
            key: confirmFieldKey,
            child: _CardField(
              controller: confirmController,
              label: 'Confirm Password',
              hint: '••••••••',
              obscure: obscureConfirm,
              onToggle: onToggleConfirm,
              onChanged: onChangedConfirm,
              fillColor: inputFill,
              isDark: isDark,
              theme: theme,
              isError: confirmTouched && !isMatch,
              hasTriedSave: hasTriedSave,
              emptyError: 'Please confirm your password',
            ),
          ),

          // ── Match status ──────────────────────────────────────────────
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: (confirmTouched && confirmController.text.isNotEmpty)
                ? Padding(
                    key: ValueKey(isMatch),
                    padding: const EdgeInsets.only(
                      top: 8.0,
                      left: 2,
                      bottom: 8.0,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          isMatch
                              ? Icons.check_circle_rounded
                              : Icons.cancel_rounded,
                          size: 14,
                          color: isMatch
                              ? AppStyles.successGreen
                              : AppStyles.errorRed,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          isMatch ? 'Passwords match' : "Passwords don't match",
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: isMatch
                                ? AppStyles.successGreen
                                : AppStyles.errorRed,
                          ),
                        ),
                      ],
                    ),
                  )
                : const SizedBox(height: 16, key: ValueKey('none')),
          ),

          const SizedBox(height: 12),

          // ── Save CTA ───────────────────────────────────────────────────
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              boxShadow: canSubmit
                  ? [
                      BoxShadow(
                        color: theme.primaryColor.withValues(alpha: 0.28),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ]
                  : [],
            ),
            child: AnimatedButton(
              onPressed: onSave,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 18),
                elevation: 0,
              ),
              child: Center(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: isLoading
                      ? const SizedBox(
                          key: ValueKey('loading'),
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Colors.white,
                          ),
                        )
                      : isSuccess
                      ? const Icon(
                          Icons.check_rounded,
                          size: 22,
                          color: Colors.white,
                          key: ValueKey('success'),
                        )
                      : Row(
                          key: const ValueKey('default'),
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: const [
                            SizedBox(width: 18),
                            Expanded(
                              child: Text(
                                'Save Password',
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 16),
                              ),
                            ),
                            Icon(Icons.arrow_forward_rounded, size: 18),
                            SizedBox(width: 12),
                          ],
                        ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Single password field inside the card ────────────────────────────────────

class _CardField extends StatefulWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final bool obscure;
  final VoidCallback onToggle;
  final ValueChanged<String> onChanged;
  final Color fillColor;
  final bool isDark;
  final ThemeData theme;
  final bool isError;
  final bool hasTriedSave;
  final String? emptyError;

  const _CardField({
    required this.controller,
    required this.label,
    required this.hint,
    required this.obscure,
    required this.onToggle,
    required this.onChanged,
    required this.fillColor,
    required this.isDark,
    required this.theme,
    required this.isError,
    required this.hasTriedSave,
    this.emptyError,
  });

  @override
  State<_CardField> createState() => _CardFieldState();
}

class _CardFieldState extends State<_CardField> {
  late FocusNode _focusNode;
  bool _isFocused = false;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    _focusNode.addListener(_handleFocus);
  }

  void _handleFocus() {
    if (mounted) {
      setState(() {
        _isFocused = _focusNode.hasFocus;
      });
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocus);
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Exact border color token matching ActivateAccountScreen._InputField
    final borderColor = widget.isDark
        ? Colors.white12
        : const Color(0xFFDDE4ED);
    final errorColor = AppStyles.errorRed;
    final explicitlyError = widget.isError;
    final effectivelyError =
        explicitlyError ||
        (widget.hasTriedSave && widget.controller.text.isEmpty);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        boxShadow: _isFocused
            ? [
                BoxShadow(
                  color: widget.theme.primaryColor.withValues(alpha: 0.18),
                  blurRadius: 10,
                ),
              ]
            : [],
      ),
      child: TextFormField(
        focusNode: _focusNode,
        controller: widget.controller,
        obscureText: widget.obscure,
        onChanged: widget.onChanged,
        textInputAction: TextInputAction.next,
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w500,
          color:
              widget.theme.textTheme.displayLarge?.color ?? AppStyles.textDark,
        ),
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: widget.hint,
          labelStyle: const TextStyle(
            color: AppStyles.textGray,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
          hintStyle: TextStyle(
            color: AppStyles.textGray.withValues(alpha: 0.5),
            fontSize: 14,
          ),
          errorText: (widget.hasTriedSave && widget.controller.text.isEmpty)
              ? widget.emptyError
              : null,
          errorStyle: const TextStyle(color: AppStyles.errorRed, fontSize: 12),
          prefixIcon: Icon(
            Icons.lock_outline_rounded,
            color: effectivelyError ? errorColor : AppStyles.textGray,
            size: 20,
          ),
          suffixIcon: IconButton(
            onPressed: widget.onToggle,
            icon: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Icon(
                widget.obscure
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                key: ValueKey(widget.obscure),
                size: 20,
                color: AppStyles.textGray,
              ),
            ),
          ),
          filled: true,
          fillColor: widget.fillColor,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
              color: effectivelyError ? errorColor : borderColor,
              width: effectivelyError ? 1.5 : 1,
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
              color: effectivelyError ? errorColor : widget.theme.primaryColor,
              width: 1.5,
            ),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppStyles.errorRed, width: 1.5),
          ),
          focusedErrorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppStyles.errorRed, width: 1.5),
          ),
        ),
      ),
    );
  }
}

// ─── Animated strength bar ────────────────────────────────────────────────────

class _StrengthBar extends StatelessWidget {
  final _Strength strength;
  final int pwLength;
  const _StrengthBar({required this.strength, required this.pwLength});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = _strengthColor(strength);
    final label = _strengthLabel(strength);
    final fraction = _strengthFraction(strength);
    final trackColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.06);

    final bool isEmpty = pwLength == 0 && strength == _Strength.empty;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 0),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
        height: isEmpty ? 0.0 : 34.0, // 24 (bar/label height) + 10 (spacing)
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          opacity: isEmpty ? 0.0 : 1.0,
          child: SingleChildScrollView(
            physics: const NeverScrollableScrollPhysics(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LayoutBuilder(
                  builder: (_, constraints) => ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Stack(
                      children: [
                        // Track
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
                                      color: color.withValues(alpha: 0.4),
                                      blurRadius: 6,
                                      offset: const Offset(0, 2),
                                    ),
                                  ]
                                : [],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (label.isNotEmpty) ...[
                  const SizedBox(height: 5),
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
                const SizedBox(height: 10),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _KeyboardGap extends StatelessWidget {
  const _KeyboardGap();

  @override
  Widget build(BuildContext context) {
    final isKeyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      height: isKeyboardOpen ? 8.0 : 24.0,
    );
  }
}

class _ShakeWidget extends StatefulWidget {
  final Widget child;
  const _ShakeWidget({super.key, required this.child});

  @override
  State<_ShakeWidget> createState() => _ShakeWidgetState();
}

class _ShakeWidgetState extends State<_ShakeWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _offsetAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );

    _offsetAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: -6.0), weight: 1),
      TweenSequenceItem(tween: Tween(begin: -6.0, end: 6.0), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 6.0, end: -6.0), weight: 2),
      TweenSequenceItem(tween: Tween(begin: -6.0, end: 6.0), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 6.0, end: 0.0), weight: 1),
    ]).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  void shake() {
    _controller.forward(from: 0.0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _offsetAnimation,
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(_offsetAnimation.value, 0),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}
