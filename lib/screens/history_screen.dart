import 'package:flutter/material.dart';
import '../utils/app_styles.dart';
import '../widgets/custom_bottom_nav.dart';
import '../widgets/fade_slide_y.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen>
    with TickerProviderStateMixin {
  late AnimationController _countController;
  late Animation<int> _verifiedCountAnimation;
  late Animation<int> _rejectedCountAnimation;

  @override
  void initState() {
    super.initState();
    _countController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );

    _verifiedCountAnimation = IntTween(begin: 0, end: 18).animate(
      CurvedAnimation(parent: _countController, curve: Curves.easeOutQuart),
    );

    _rejectedCountAnimation = IntTween(begin: 0, end: 3).animate(
      CurvedAnimation(parent: _countController, curve: Curves.easeOutQuart),
    );

    _countController.forward();
  }

  @override
  void dispose() {
    _countController.dispose();
    super.dispose();
  }

  void _onNavTap(int index) {
    if (index == 0) Navigator.of(context).pushReplacementNamed('/dashboard');
    if (index == 1) return;
    if (index == 2) Navigator.of(context).pushReplacementNamed('/settings');
    if (index == 3) Navigator.of(context).pushReplacementNamed('/profile');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'History',
              style: TextStyle(
                color:
                    theme.textTheme.displayLarge?.color ?? AppStyles.textDark,
                fontWeight: FontWeight.bold,
                fontSize: 24,
              ),
            ),
            Text(
              'Oct 24, 2024',
              style: TextStyle(
                color: AppStyles.textGray.withValues(alpha: 0.8),
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            // ── Summary Cards ───────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
              child: FadeSlideY(
                delay: const Duration(milliseconds: 100),
                child: Row(
                  children: [
                    Expanded(
                      child: _SummaryCard(
                        label: 'Verified',
                        countAnimation: _verifiedCountAnimation,
                        dotColor: AppStyles.successGreen,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: _SummaryCard(
                        label: 'Rejected',
                        countAnimation: _rejectedCountAnimation,
                        dotColor: AppStyles.errorRed,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // ── Day-Grouped History List ─────────────────────────────────────
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
                children: [
                  // Today group
                  FadeSlideY(
                    delay: const Duration(milliseconds: 200),
                    child: _DayGroup(
                      label: 'Today',
                      items: const [
                        _AttendanceRecord(
                          isSuccess: true,
                          time: '09:05 AM',
                          status: 'Present',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  // Yesterday group (multiple attempts)
                  FadeSlideY(
                    delay: const Duration(milliseconds: 340),
                    child: _DayGroup(
                      label: 'Yesterday',
                      items: const [
                        _AttendanceRecord(
                          isSuccess: false,
                          time: '08:55 AM',
                          status: 'Failed',
                        ),
                        _AttendanceRecord(
                          isSuccess: true,
                          time: '09:15 AM',
                          status: 'Present',
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: CustomBottomNav(currentIndex: 1, onTap: _onNavTap),
    );
  }
}

// ─── Summary Card (Animated count) ────────────────────────────────────────────
class _SummaryCard extends AnimatedWidget {
  final String label;
  final Color dotColor;
  final Animation<int> countAnimation;

  const _SummaryCard({
    required this.label,
    required this.dotColor,
    required this.countAnimation,
  }) : super(listenable: countAnimation);

  @override
  Widget build(BuildContext context) {
    final cardBase = Theme.of(context).cardTheme.color;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
      decoration: BoxDecoration(
        color: cardBase != null
            ? Color.alphaBlend(dotColor.withValues(alpha: 0.06), cardBase)
            : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: dotColor.withValues(alpha: 0.15), width: 1),
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
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: dotColor,
                ),
              ),
              const SizedBox(width: 7),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppStyles.textGray,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            countAnimation.value.toString(),
            style: TextStyle(
              fontSize: 36,
              fontWeight: FontWeight.w800,
              color:
                  Theme.of(context).textTheme.displayLarge?.color ??
                  AppStyles.textDark,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Day Group Container ───────────────────────────────────────────────────────
class _DayGroup extends StatelessWidget {
  final String label;
  final List<_AttendanceRecord> items;

  const _DayGroup({required this.label, required this.items});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cardColor = theme.cardTheme.color ?? Colors.white;
    final isDark = theme.brightness == Brightness.dark;
    final dividerColor = isDark ? Colors.white12 : const Color(0xFFE8EDF2);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Day label
        Padding(
          padding: const EdgeInsets.only(bottom: 10.0, left: 2),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: theme.textTheme.bodyMedium?.color ?? AppStyles.textGray,
              letterSpacing: 0.5,
            ),
          ),
        ),
        // All attempts in one unified card
        Container(
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.06),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            children: [
              for (int i = 0; i < items.length; i++) ...[
                _HistoryRow(record: items[i]),
                if (i < items.length - 1)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0),
                    child: Divider(height: 1, color: dividerColor),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// Internal record data class
class _AttendanceRecord {
  final bool isSuccess;
  final String time;
  final String status;
  const _AttendanceRecord({
    required this.isSuccess,
    required this.time,
    required this.status,
  });
}

// ─── History Row (inside a Day Group) ─────────────────────────────────────────
class _HistoryRow extends StatefulWidget {
  final _AttendanceRecord record;
  const _HistoryRow({required this.record});

  @override
  State<_HistoryRow> createState() => _HistoryRowState();
}

class _HistoryRowState extends State<_HistoryRow>
    with SingleTickerProviderStateMixin {
  late AnimationController _badgeController;
  late Animation<double> _badgeScale;

  @override
  void initState() {
    super.initState();
    _badgeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _badgeScale = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _badgeController, curve: Curves.easeOutBack),
    );
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) _badgeController.forward();
    });
  }

  @override
  void dispose() {
    _badgeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isSuccess = widget.record.isSuccess;
    final color = isSuccess ? AppStyles.successGreen : AppStyles.errorRed;
    final title = isSuccess ? 'Face Verified' : 'Verification Failed';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 14.0),
      child: Row(
        children: [
          // Status icon
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              isSuccess ? Icons.check_circle_rounded : Icons.cancel_rounded,
              color: color,
              size: 20,
            ),
          ),
          const SizedBox(width: 14),
          // Title + time
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color:
                        theme.textTheme.displayLarge?.color ??
                        AppStyles.textDark,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  widget.record.time,
                  style: TextStyle(
                    fontSize: 13,
                    color:
                        theme.textTheme.bodyMedium?.color ?? AppStyles.textGray,
                  ),
                ),
              ],
            ),
          ),
          // Animated status badge
          ScaleTransition(
            scale: _badgeScale,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                widget.record.status,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
