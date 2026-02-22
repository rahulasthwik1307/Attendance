import 'package:flutter/material.dart';
import '../utils/app_styles.dart';
import '../widgets/animated_button.dart';
import '../widgets/fade_slide_y.dart';
import '../utils/auth_flow_state.dart';

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _rollController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  final _rollFieldKey = GlobalKey<_ShakeWidgetState>();
  final _passwordFieldKey = GlobalKey<_ShakeWidgetState>();

  bool _obscurePassword = true;
  bool _isLoading = false;
  // Only validate after the first submit attempt
  bool _hasTried = false;
  bool _isSuccess = false;

  @override
  void dispose() {
    _rollController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _onSignIn() async {
    if (_isSuccess || _isLoading) return;
    setState(() => _hasTried = true);

    bool rollValid = _rollController.text.trim().isNotEmpty;
    bool passValid = _passwordController.text.length >= 6;

    if (!rollValid) _rollFieldKey.currentState?.shake();
    if (!passValid) _passwordFieldKey.currentState?.shake();

    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (!rollValid || !passValid) return;

    setState(() => _isLoading = true);
    // Simulate auth — replace with real call.
    await Future.delayed(const Duration(milliseconds: 900));
    if (!mounted) return;
    setState(() {
      _isLoading = false;
      _isSuccess = true;
    });

    await Future.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;

    // Set password as set (since they signed in successfully with one)
    AuthFlowState.instance.passwordSet = true;

    // Check if face registration is actually complete
    if (AuthFlowState.instance.faceRegistered) {
      Navigator.of(context).pushReplacementNamed('/dashboard');
    } else {
      // Force face registration if not done
      Navigator.of(context).pushReplacementNamed('/register');
    }
  }

  void _onForgotPassword() {
    Navigator.of(context).pushNamed('/forgot_password');
  }

  Widget _buildHeader(
    ThemeData theme,
    Color headingColor,
    Color subtitleColor,
  ) {
    return Column(
      children: [
        FadeSlideY(
          delay: const Duration(milliseconds: 60),
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: theme.primaryColor.withValues(alpha: 0.09),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Icon(
              Icons.login_rounded,
              size: 32,
              color: theme.primaryColor,
            ),
          ),
        ),
        const SizedBox(height: 20),
        FadeSlideY(
          delay: const Duration(milliseconds: 140),
          child: Text(
            'Sign In',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.4,
              height: 1.15,
              color: headingColor,
            ),
          ),
        ),
        const SizedBox(height: 8),
        FadeSlideY(
          delay: const Duration(milliseconds: 220),
          child: Text(
            'Welcome back. Enter your credentials to continue.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, height: 1.5, color: subtitleColor),
          ),
        ),
      ],
    );
  }

  Widget _buildFormCard(
    ThemeData theme,
    Color surfaceColor,
    Color borderColor,
    Color inputFill,
    bool isDark,
  ) {
    return FadeSlideY(
      delay: const Duration(milliseconds: 340),
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
        decoration: BoxDecoration(
          color: surfaceColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: borderColor, width: 1.2),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
              blurRadius: 24,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Form(
          key: _formKey,
          autovalidateMode: _hasTried
              ? AutovalidateMode.onUserInteraction
              : AutovalidateMode.disabled,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _ShakeWidget(
                key: _rollFieldKey,
                child: _SignInField(
                  controller: _rollController,
                  label: 'Roll Number',
                  hint: 'e.g. 2023-CS-001',
                  prefixIcon: Icons.badge_outlined,
                  fillColor: inputFill,
                  borderColor: borderColor,
                  textInputAction: TextInputAction.next,
                  isDark: isDark,
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'Please enter your roll number'
                      : null,
                ),
              ),
              const SizedBox(height: 14),
              _ShakeWidget(
                key: _passwordFieldKey,
                child: _SignInField(
                  controller: _passwordController,
                  label: 'Password',
                  hint: '••••••••',
                  prefixIcon: Icons.lock_outline_rounded,
                  fillColor: inputFill,
                  borderColor: borderColor,
                  obscureText: _obscurePassword,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _onSignIn(),
                  isDark: isDark,
                  validator: (v) {
                    if (v == null || v.isEmpty) {
                      return 'Please enter your password';
                    }
                    if (v.length < 6) {
                      return 'At least 6 characters required';
                    }
                    return null;
                  },
                  suffixIcon: IconButton(
                    icon: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: Icon(
                        _obscurePassword
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        key: ValueKey(_obscurePassword),
                        size: 20,
                        color: isDark
                            ? Colors.grey.shade500
                            : Colors.grey.shade400,
                      ),
                    ),
                    onPressed: () =>
                        setState(() => _obscurePassword = !_obscurePassword),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              _isLoading
                  ? _LoadingButton(theme: theme)
                  : Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: [
                          BoxShadow(
                            color: theme.primaryColor.withValues(alpha: 0.28),
                            blurRadius: 14,
                            offset: const Offset(0, 5),
                          ),
                        ],
                      ),
                      child: AnimatedButton(
                        onPressed: _onSignIn,
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 18),
                          elevation: 0,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Text(
                              'Sign In',
                              style: TextStyle(fontSize: 16),
                            ),
                            const SizedBox(width: 8),
                            AnimatedSwitcher(
                              duration: const Duration(milliseconds: 200),
                              child: Icon(
                                _isSuccess
                                    ? Icons.check_rounded
                                    : Icons.arrow_forward_rounded,
                                key: ValueKey(_isSuccess),
                                size: 18,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
            ],
          ),
        ),
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

    final surfaceColor = isDark ? AppStyles.surfaceDark : Colors.white;
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.10)
        : Colors.black.withValues(alpha: 0.07);
    final inputFill = isDark
        ? AppStyles.surfaceDark.withValues(alpha: 0.6)
        : AppStyles.backgroundLight;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back_ios_new_rounded,
            size: 20,
            color: headingColor,
          ),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
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
                      _buildHeader(theme, headingColor, subtitleColor),
                      const _KeyboardGap(),
                      _buildFormCard(
                        theme,
                        surfaceColor,
                        borderColor,
                        inputFill,
                        isDark,
                      ),
                      const SizedBox(height: 8),
                      Center(
                        child: TextButton(
                          onPressed: _onForgotPassword,
                          style: TextButton.styleFrom(
                            foregroundColor: theme.primaryColor,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                          ),
                          child: const Text(
                            'Forgot Password?',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

// ─── Reusable input widget (mirrors Set New Password / Activate Account) ────────
class _SignInField extends StatefulWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final IconData prefixIcon;
  final Color fillColor;
  final Color borderColor;
  final bool obscureText;
  final TextInputAction textInputAction;
  final String? Function(String?)? validator;
  final Widget? suffixIcon;
  final void Function(String)? onFieldSubmitted;
  final bool isDark;

  const _SignInField({
    required this.controller,
    required this.label,
    required this.hint,
    required this.prefixIcon,
    required this.fillColor,
    required this.borderColor,
    required this.isDark,
    this.obscureText = false,
    this.textInputAction = TextInputAction.next,
    this.validator,
    this.suffixIcon,
    this.onFieldSubmitted,
  });

  @override
  State<_SignInField> createState() => _SignInFieldState();
}

class _SignInFieldState extends State<_SignInField> {
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
    final theme = Theme.of(context);
    // Soft muted red — calmer than AppStyles.errorRed
    const softErrorColor = Color(0xFFD05050);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: widget.isDark ? Colors.grey.shade300 : AppStyles.textDark,
            letterSpacing: 0.1,
          ),
        ),
        const SizedBox(height: 7),
        AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            boxShadow: _isFocused
                ? [
                    BoxShadow(
                      color: theme.primaryColor.withValues(alpha: 0.18),
                      blurRadius: 10,
                    ),
                  ]
                : [],
          ),
          child: TextFormField(
            focusNode: _focusNode,
            controller: widget.controller,
            obscureText: widget.obscureText,
            textInputAction: widget.textInputAction,
            onFieldSubmitted: widget.onFieldSubmitted,
            validator: widget.validator,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: theme.textTheme.displayLarge?.color ?? AppStyles.textDark,
            ),
            decoration: InputDecoration(
              hintText: widget.hint,
              hintStyle: TextStyle(
                color: AppStyles.textGray.withValues(alpha: 0.45),
                fontSize: 14,
              ),
              prefixIcon: Icon(
                widget.prefixIcon,
                size: 20,
                color: AppStyles.textGray.withValues(alpha: 0.65),
              ),
              suffixIcon: widget.suffixIcon,
              filled: true,
              fillColor: widget.fillColor,
              // Keep error text small and calm
              errorStyle: const TextStyle(
                fontSize: 11.5,
                color: softErrorColor,
                fontWeight: FontWeight.w500,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 16,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: widget.borderColor, width: 1),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: theme.primaryColor, width: 1.5),
              ),
              errorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: softErrorColor, width: 1.2),
              ),
              focusedErrorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: softErrorColor, width: 1.5),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Inline loading state (same height as the button) ─────────────────────────
class _LoadingButton extends StatelessWidget {
  final ThemeData theme;
  const _LoadingButton({required this.theme});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      decoration: BoxDecoration(
        color: theme.primaryColor,
        borderRadius: BorderRadius.circular(14),
      ),
      alignment: Alignment.center,
      child: const SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(
          strokeWidth: 2.5,
          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
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
