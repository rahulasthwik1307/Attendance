import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../utils/app_styles.dart';
import '../../widgets/custom_bottom_nav.dart';
import '../../widgets/fade_slide_y.dart';

import 'dart:math' as math;

const List<Map<String, dynamic>> _subjectAttendance = [
  {
    'subject': 'Software Engineering',
    'code': 'SE',
    'held': 30,
    'attended': 18,
    'faculty': 'Dr. V. Singh',
  },
  {
    'subject': 'DBMS',
    'code': 'DB',
    'held': 38,
    'attended': 26,
    'faculty': 'Dr. P. Sharma',
  },
  {
    'subject': 'Computer Networks',
    'code': 'CN',
    'held': 36,
    'attended': 30,
    'faculty': 'Prof. A. Rao',
  },
  {
    'subject': 'Operating Systems',
    'code': 'OS',
    'held': 40,
    'attended': 32,
    'faculty': 'Prof. S. Mehta',
  },
  {
    'subject': 'Data Structures',
    'code': 'DS',
    'held': 42,
    'attended': 38,
    'faculty': 'Dr. R. Kumar',
  },
];

const List<Map<String, dynamic>> _collegeAttendance = [
  {
    'dateLabel': 'Today',
    'fullDate': 'Oct 24, 2024',
    'time': '09:05 AM',
    'status': 'present',
  },
  {
    'dateLabel': 'Yesterday',
    'fullDate': 'Oct 23, 2024',
    'time': '09:12 AM',
    'status': 'present',
  },
  {
    'dateLabel': 'Sat • Oct 22',
    'fullDate': 'Oct 22, 2024',
    'time': '—',
    'status': 'absent',
  },
  {
    'dateLabel': 'Fri • Oct 21',
    'fullDate': 'Oct 21, 2024',
    'time': '08:58 AM',
    'status': 'present',
  },
  {
    'dateLabel': 'Thu • Oct 20',
    'fullDate': 'Oct 20, 2024',
    'time': '09:20 AM',
    'status': 'late',
  },
  {
    'dateLabel': 'Wed • Oct 19',
    'fullDate': 'Oct 19, 2024',
    'time': '09:01 AM',
    'status': 'present',
  },
  {
    'dateLabel': 'Tue • Oct 18',
    'fullDate': 'Oct 18, 2024',
    'time': '—',
    'status': 'absent',
  },
];

const List<Map<String, dynamic>> _classAttendance = [
  {
    'dateGroup': 'Today • Oct 24, 2024',
    'subject': 'Data Structures',
    'period': '1st Period',
    'time': '09:05 AM',
    'status': 'present',
  },
  {
    'dateGroup': 'Today • Oct 24, 2024',
    'subject': 'Operating Systems',
    'period': '2nd Period',
    'time': '10:10 AM',
    'status': 'present',
  },
  {
    'dateGroup': 'Today • Oct 24, 2024',
    'subject': 'DBMS',
    'period': '3rd Period',
    'time': '—',
    'status': 'absent',
  },
  {
    'dateGroup': 'Yesterday • Oct 23, 2024',
    'subject': 'Computer Networks',
    'period': '1st Period',
    'time': '09:08 AM',
    'status': 'present',
  },
  {
    'dateGroup': 'Yesterday • Oct 23, 2024',
    'subject': 'Data Structures',
    'period': '2nd Period',
    'time': '10:15 AM',
    'status': 'present',
  },
  {
    'dateGroup': 'Yesterday • Oct 23, 2024',
    'subject': 'Software Engineering',
    'period': '4th Period',
    'time': '—',
    'status': 'absent',
  },
  {
    'dateGroup': 'Fri • Oct 21, 2024',
    'subject': 'Operating Systems',
    'period': '1st Period',
    'time': '09:00 AM',
    'status': 'present',
  },
  {
    'dateGroup': 'Fri • Oct 21, 2024',
    'subject': 'DBMS',
    'period': '2nd Period',
    'time': '10:05 AM',
    'status': 'present',
  },
];

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen>
    with TickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
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
    final isDark = theme.brightness == Brightness.dark;

    final int collegePresentCount = _collegeAttendance
        .where((e) => e['status'] == 'present')
        .length;
    final int collegeTotal = _collegeAttendance.length;
    final int classPresentCount = _classAttendance
        .where((e) => e['status'] == 'present')
        .length;
    final int classTotal = _classAttendance.length;

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
                'Oct 2024',
                style: TextStyle(
                  color: AppStyles.textGray.withValues(alpha: 0.8),
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(48),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.08)
                    : Colors.black.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(12),
              ),
              child: TabBar(
                controller: _tabController,
                indicator: BoxDecoration(
                  color: theme.primaryColor,
                  borderRadius: BorderRadius.circular(10),
                ),
                indicatorSize: TabBarIndicatorSize.tab,
                labelColor: Colors.white,
                unselectedLabelColor: AppStyles.textGray,
                labelStyle: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
                unselectedLabelStyle: const TextStyle(
                  fontWeight: FontWeight.w500,
                  fontSize: 13,
                ),
                dividerColor: Colors.transparent,
                tabs: const [
                  Tab(text: 'College'),
                  Tab(text: 'Classes'),
                  Tab(text: 'Subjects'),
                ],
              ),
            ),
          ),
        ),
        body: SafeArea(
          child: TabBarView(
            controller: _tabController,
            children: [
              _CollegeAttendanceTab(
                isDark: isDark,
                theme: theme,
                presentCount: collegePresentCount,
                totalCount: collegeTotal,
                records: _collegeAttendance,
              ),
              _ClassAttendanceTab(
                isDark: isDark,
                theme: theme,
                presentCount: classPresentCount,
                totalCount: classTotal,
                records: _classAttendance,
              ),
              _SubjectsTab(
                isDark: isDark,
                theme: theme,
                records: _subjectAttendance,
              ),
            ],
          ),
        ),
        bottomNavigationBar: CustomBottomNav(currentIndex: 1, onTap: _onNavTap),
      ),
    );
  }
}

class _CollegeAttendanceTab extends StatelessWidget {
  final bool isDark;
  final ThemeData theme;
  final int presentCount;
  final int totalCount;
  final List<Map<String, dynamic>> records;

  const _CollegeAttendanceTab({
    required this.isDark,
    required this.theme,
    required this.presentCount,
    required this.totalCount,
    required this.records,
  });

  @override
  Widget build(BuildContext context) {
    final int absentCount = records
        .where((e) => e['status'] == 'absent')
        .length;
    final int lateCount = records.where((e) => e['status'] == 'late').length;
    final double pct = totalCount > 0 ? presentCount / totalCount : 0;
    final Color pctColor = pct >= 0.75
        ? AppStyles.successGreen
        : pct >= 0.65
        ? AppStyles.warningYellow
        : AppStyles.errorRed;

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      children: [
        FadeSlideY(
          delay: const Duration(milliseconds: 100),
          child: Row(
            children: [
              Expanded(
                child: _StatChip(
                  label: 'Present',
                  value: '$presentCount',
                  color: AppStyles.successGreen,
                  isDark: isDark,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _StatChip(
                  label: 'Absent',
                  value: '$absentCount',
                  color: AppStyles.errorRed,
                  isDark: isDark,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _StatChip(
                  label: 'Late',
                  value: '$lateCount',
                  color: AppStyles.warningYellow,
                  isDark: isDark,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        FadeSlideY(
          delay: const Duration(milliseconds: 180),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: theme.cardTheme.color ?? Colors.white,
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.15 : 0.05),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'This Month — Presence',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color:
                              theme.textTheme.bodyMedium?.color ??
                              AppStyles.textGray,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: pctColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        '${(pct * 100).round()}%',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: pctColor,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: pct),
                  duration: const Duration(milliseconds: 1200),
                  curve: Curves.easeOutCubic,
                  builder: (_, value, _) => ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: value,
                      minHeight: 7,
                      backgroundColor: isDark
                          ? Colors.white.withValues(alpha: 0.08)
                          : Colors.black.withValues(alpha: 0.06),
                      valueColor: AlwaysStoppedAnimation<Color>(pctColor),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        ...records.asMap().entries.map((entry) {
          final i = entry.key;
          final record = entry.value;
          final status = record['status'] as String;
          final Color statusColor = status == 'present'
              ? AppStyles.successGreen
              : status == 'late'
              ? AppStyles.warningYellow
              : AppStyles.errorRed;
          final IconData statusIcon = status == 'present'
              ? Icons.check_circle_rounded
              : status == 'late'
              ? Icons.schedule_rounded
              : Icons.cancel_rounded;
          final String statusLabel = status == 'present'
              ? 'Present'
              : status == 'late'
              ? 'Late'
              : 'Absent';
          final dateLabel = record['dateLabel'] as String;

          return FadeSlideY(
            delay: Duration(milliseconds: 220 + (i * 60)),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: theme.cardTheme.color ?? Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: isDark ? 0.15 : 0.05,
                      ),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    // Date chip — day on top, date below
                    Container(
                      width: 58,
                      padding: const EdgeInsets.symmetric(
                        vertical: 8,
                        horizontal: 4,
                      ),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            dateLabel.contains('•')
                                ? dateLabel.split('•').first.trim()
                                : dateLabel,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: statusColor,
                              height: 1.3,
                            ),
                          ),
                          if (dateLabel.contains('•')) ...[
                            const SizedBox(height: 2),
                            Text(
                              dateLabel.split('•').last.trim(),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: statusColor,
                                height: 1.2,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 14),
                    // Event info only — no date repeated
                    Expanded(
                      child: Text(
                        status == 'absent'
                            ? 'Not marked'
                            : 'Entered at ${record['time']}',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color:
                              theme.textTheme.displayLarge?.color ??
                              AppStyles.textDark,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Status pill
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(statusIcon, size: 12, color: statusColor),
                          const SizedBox(width: 4),
                          Text(
                            statusLabel,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: statusColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
      ],
    );
  }
}

class _ClassAttendanceTab extends StatelessWidget {
  final bool isDark;
  final ThemeData theme;
  final int presentCount;
  final int totalCount;
  final List<Map<String, dynamic>> records;

  const _ClassAttendanceTab({
    required this.isDark,
    required this.theme,
    required this.presentCount,
    required this.totalCount,
    required this.records,
  });

  @override
  Widget build(BuildContext context) {
    final int absentCount = records
        .where((e) => e['status'] == 'absent')
        .length;

    // Group records by dateGroup
    final Map<String, List<Map<String, dynamic>>> grouped = {};
    for (final record in records) {
      final key = record['dateGroup'] as String;
      grouped.putIfAbsent(key, () => []).add(record);
    }
    final groups = grouped.entries.toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      children: [
        FadeSlideY(
          delay: const Duration(milliseconds: 100),
          child: Row(
            children: [
              Expanded(
                child: _StatChip(
                  label: 'Present',
                  value: '$presentCount',
                  color: AppStyles.successGreen,
                  isDark: isDark,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _StatChip(
                  label: 'Absent',
                  value: '$absentCount',
                  color: AppStyles.errorRed,
                  isDark: isDark,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        ...groups.asMap().entries.map((groupEntry) {
          final gi = groupEntry.key;
          final groupDate = groupEntry.value.key;
          final groupRecords = groupEntry.value.value;

          return FadeSlideY(
            delay: Duration(milliseconds: 160 + (gi * 80)),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Date header with accent line
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      children: [
                        Container(
                          width: 3,
                          height: 16,
                          decoration: BoxDecoration(
                            color: theme.primaryColor,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          groupDate,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color:
                                theme.textTheme.displayLarge?.color ??
                                AppStyles.textDark,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // All periods in unified card
                  Container(
                    decoration: BoxDecoration(
                      color: theme.cardTheme.color ?? Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(
                            alpha: isDark ? 0.15 : 0.05,
                          ),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        for (int pi = 0; pi < groupRecords.length; pi++) ...[
                          _ClassPeriodRow(
                            record: groupRecords[pi],
                            theme: theme,
                            isDark: isDark,
                          ),
                          if (pi < groupRecords.length - 1)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              child: Divider(
                                height: 1,
                                color: isDark
                                    ? Colors.white.withValues(alpha: 0.08)
                                    : Colors.black.withValues(alpha: 0.06),
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }
}

class _ClassPeriodRow extends StatelessWidget {
  final Map<String, dynamic> record;
  final ThemeData theme;
  final bool isDark;

  const _ClassPeriodRow({
    required this.record,
    required this.theme,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final status = record['status'] as String;
    final Color statusColor = status == 'present'
        ? AppStyles.successGreen
        : AppStyles.errorRed;
    final IconData statusIcon = status == 'present'
        ? Icons.check_circle_rounded
        : Icons.cancel_rounded;
    final String statusLabel = status == 'present' ? 'Present' : 'Absent';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: theme.primaryColor.withValues(alpha: 0.09),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              Icons.menu_book_rounded,
              color: theme.primaryColor,
              size: 18,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  record['subject'] as String,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color:
                        theme.textTheme.displayLarge?.color ??
                        AppStyles.textDark,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  status == 'absent'
                      ? record['period'] as String
                      : '${record['period']}  •  ${record['time']}',
                  style: TextStyle(
                    fontSize: 12,
                    color:
                        theme.textTheme.bodyMedium?.color ?? AppStyles.textGray,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(statusIcon, size: 12, color: statusColor),
                const SizedBox(width: 4),
                Text(
                  statusLabel,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: statusColor,
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

class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final bool isDark;

  const _StatChip({
    required this.label,
    required this.value,
    required this.color,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.15 : 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.2), width: 1),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: color,
              height: 1,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: theme.textTheme.bodyMedium?.color ?? AppStyles.textGray,
            ),
          ),
        ],
      ),
    );
  }
}

class _ArcPainter extends CustomPainter {
  final double progress;
  final bool isDark;
  final Color color;
  final double strokeWidth;

  const _ArcPainter({
    required this.progress,
    required this.isDark,
    required this.color,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - strokeWidth) / 2;

    final trackPaint = Paint()
      ..color = isDark
          ? Colors.white.withValues(alpha: 0.08)
          : Colors.black.withValues(alpha: 0.06)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    final arcPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    const startAngle = -math.pi / 2;
    const fullSweep = 2 * math.pi;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      fullSweep,
      false,
      trackPaint,
    );

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      fullSweep * progress,
      false,
      arcPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _ArcPainter old) =>
      old.progress != progress ||
      old.isDark != isDark ||
      old.color != color ||
      old.strokeWidth != strokeWidth;
}

class _SubjectsTab extends StatelessWidget {
  final bool isDark;
  final ThemeData theme;
  final List<Map<String, dynamic>> records;

  const _SubjectsTab({
    required this.isDark,
    required this.theme,
    required this.records,
  });

  @override
  Widget build(BuildContext context) {
    final int totalHeld = records.fold(0, (sum, e) => sum + (e['held'] as int));
    final int totalAttended = records.fold(
      0,
      (sum, e) => sum + (e['attended'] as int),
    );
    final double overallPct = totalHeld > 0 ? totalAttended / totalHeld : 0;
    final Color overallColor = overallPct >= 0.75
        ? AppStyles.successGreen
        : overallPct >= 0.65
        ? AppStyles.warningYellow
        : AppStyles.errorRed;

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      children: [
        // Overall summary card
        FadeSlideY(
          delay: const Duration(milliseconds: 80),
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  overallColor.withValues(alpha: isDark ? 0.2 : 0.1),
                  overallColor.withValues(alpha: isDark ? 0.08 : 0.03),
                ],
              ),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: overallColor.withValues(alpha: 0.25),
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Overall Academic Attendance',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color:
                              theme.textTheme.bodyMedium?.color ??
                              AppStyles.textGray,
                        ),
                      ),
                      const SizedBox(height: 4),
                      RichText(
                        text: TextSpan(
                          children: [
                            TextSpan(
                              text: '$totalAttended',
                              style: TextStyle(
                                fontSize: 26,
                                fontWeight: FontWeight.w800,
                                color:
                                    theme.textTheme.displayLarge?.color ??
                                    AppStyles.textDark,
                                letterSpacing: -0.5,
                              ),
                            ),
                            TextSpan(
                              text: ' / $totalHeld classes',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color:
                                    theme.textTheme.bodyMedium?.color ??
                                    AppStyles.textGray,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: overallColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          overallPct >= 0.75
                              ? 'Good Standing — Above 75%'
                              : overallPct >= 0.60
                              ? 'Warning — Below 75%'
                              : 'Critical — Immediate Attention Needed',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: overallColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                _MiniArc(
                  percentage: overallPct,
                  color: overallColor,
                  size: 72,
                  strokeWidth: 7,
                  isDark: isDark,
                  theme: theme,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        FadeSlideY(
          delay: const Duration(milliseconds: 140),
          child: Text(
            'Subject Wise Breakdown',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: theme.textTheme.displayLarge?.color ?? AppStyles.textDark,
            ),
          ),
        ),
        const SizedBox(height: 12),
        ...records.asMap().entries.map((entry) {
          final i = entry.key;
          final record = entry.value;
          return FadeSlideY(
            delay: Duration(milliseconds: 200 + (i * 80)),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: _SubjectArcCard(
                record: record,
                isDark: isDark,
                theme: theme,
              ),
            ),
          );
        }),
      ],
    );
  }
}

class _SubjectArcCard extends StatefulWidget {
  final Map<String, dynamic> record;
  final bool isDark;
  final ThemeData theme;

  const _SubjectArcCard({
    required this.record,
    required this.isDark,
    required this.theme,
  });

  @override
  State<_SubjectArcCard> createState() => _SubjectArcCardState();
}

class _SubjectArcCardState extends State<_SubjectArcCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _progressAnim;
  late Animation<int> _counterAnim;

  @override
  void initState() {
    super.initState();
    final int held = widget.record['held'] as int;
    final int attended = widget.record['attended'] as int;
    final double pct = held > 0 ? attended / held : 0;
    final int pctInt = (pct * 100).round();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    _progressAnim = Tween<double>(
      begin: 0,
      end: pct,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    _counterAnim = IntTween(
      begin: 0,
      end: pctInt,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final int held = widget.record['held'] as int;
    final int attended = widget.record['attended'] as int;
    final double pct = held > 0 ? attended / held : 0;
    final Color color = pct >= 0.75
        ? AppStyles.successGreen
        : pct >= 0.65
        ? AppStyles.warningYellow
        : AppStyles.errorRed;
    final isDark = widget.isDark;
    final theme = widget.theme;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.cardTheme.color ?? Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.18 : 0.05),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: [
          AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              return _MiniArc(
                percentage: _progressAnim.value,
                color: color,
                size: 72,
                strokeWidth: 7,
                isDark: isDark,
                theme: theme,
                counterValue: _counterAnim.value,
              );
            },
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.record['subject'] as String,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color:
                        theme.textTheme.displayLarge?.color ??
                        AppStyles.textDark,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  widget.record['faculty'] as String,
                  style: TextStyle(
                    fontSize: 12,
                    color:
                        theme.textTheme.bodyMedium?.color ?? AppStyles.textGray,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    _InfoChip(label: '$attended Attended', color: color),
                    const SizedBox(width: 6),
                    _InfoChip(
                      label: '$held Total',
                      color:
                          theme.textTheme.bodyMedium?.color ??
                          AppStyles.textGray,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                _InfoChip(
                  label: pct >= 0.75
                      ? 'Good Standing'
                      : pct >= 0.65
                      ? 'Below Required — Warning'
                      : 'Critical — Immediate Action',
                  color: color,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniArc extends StatelessWidget {
  final double percentage;
  final Color color;
  final double size;
  final double strokeWidth;
  final bool isDark;
  final ThemeData theme;
  final int? counterValue;

  const _MiniArc({
    required this.percentage,
    required this.color,
    required this.size,
    required this.strokeWidth,
    required this.isDark,
    required this.theme,
    this.counterValue,
  });

  @override
  Widget build(BuildContext context) {
    final displayValue = counterValue ?? (percentage * 100).round();
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _ArcPainter(
          progress: percentage,
          isDark: isDark,
          color: color,
          strokeWidth: strokeWidth,
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RichText(
                text: TextSpan(
                  children: [
                    TextSpan(
                      text: '$displayValue',
                      style: TextStyle(
                        fontSize: size * 0.24,
                        fontWeight: FontWeight.w800,
                        color: color,
                        letterSpacing: -0.5,
                        height: 1,
                      ),
                    ),
                    TextSpan(
                      text: '%',
                      style: TextStyle(
                        fontSize: size * 0.13,
                        fontWeight: FontWeight.w700,
                        color: color.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final String label;
  final Color color;
  const _InfoChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.2), width: 1),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}
