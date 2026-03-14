import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/supabase_service.dart';
import '../../utils/app_styles.dart';
import '../../widgets/custom_bottom_nav.dart';
import '../../widgets/fade_slide_y.dart';

import 'dart:math' as math;

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen>
    with TickerProviderStateMixin {
  late TabController _tabController;
  late AnimationController _headerAnimController;
  late Animation<double> _headerFadeAnim;
  late Animation<Offset> _headerSlideAnim;

  // Month/year selection state
  int _selectedYear = DateTime.now().year;
  String _selectedMonthAbbr = _monthAbbreviations[DateTime.now().month - 1];
  bool _pillPressed = false;
  bool _sheetOpen = false;

  String get _selectedMonthLabel => '$_selectedMonthAbbr $_selectedYear';

  // Dynamic data state
  String? _studentClassId;

  // College tab
  List<Map<String, dynamic>> _collegeRecords = [];

  // Classes tab
  List<Map<String, dynamic>> _classRecords = [];

  // Subjects tab
  List<Map<String, dynamic>> _subjectRecords = [];

  // Timetable tab
  List<Map<String, dynamic>> _timetableSlots = [];
  bool _timetableLoading = true;

  // Available months per year — derived from real data
  Map<int, List<String>> _availableMonths = {};

  static const List<String> _monthAbbreviations = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);

    _headerAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _headerFadeAnim = CurvedAnimation(
      parent: _headerAnimController,
      curve: Curves.easeOut,
    );
    _headerSlideAnim =
        Tween<Offset>(begin: const Offset(0, -0.25), end: Offset.zero).animate(
          CurvedAnimation(
            parent: _headerAnimController,
            curve: Curves.easeOutCubic,
          ),
        );
    // Start header entry animation after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _headerAnimController.forward();
    });
    _loadStudentClass();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _headerAnimController.dispose();
    super.dispose();
  }

  void _onNavTap(int index) {
    if (index == 0) Navigator.of(context).pushReplacementNamed('/dashboard');
    if (index == 1) return;
    if (index == 2) Navigator.of(context).pushReplacementNamed('/settings');
    if (index == 3) Navigator.of(context).pushReplacementNamed('/profile');
  }

  // ── Data fetching ──────────────────────────────────────────────────────────

  Future<void> _loadStudentClass() async {
    try {
      final user = supabase.auth.currentUser;
      if (user == null) return;
      final studentData = await supabase
          .from('students')
          .select('class_id')
          .eq('id', user.id)
          .maybeSingle();
      if (studentData == null) return;
      _studentClassId = studentData['class_id'] as String;
      await _fetchAllData();
    } catch (e) {
      debugPrint('[HISTORY] loadStudentClass error: $e');
    }
  }

  Future<void> _fetchAllData() async {
    if (!mounted) return;
    await Future.wait([
      _fetchCollegeData(),
      _fetchClassData(),
      _fetchSubjectData(),
      _fetchTimetableData(),
    ]);
    _buildAvailableMonths();
  }

  Future<void> _fetchCollegeData() async {
    try {
      final user = supabase.auth.currentUser;
      if (user == null) return;

      final records = await supabase
          .from('college_attendance')
          .select('id, date, marked_at, status')
          .eq('student_id', user.id)
          .order('date', ascending: false)
          .limit(60);

      final List<Map<String, dynamic>> built = [];
      for (final r in records) {
        final dateStr = r['date'] as String;
        final markedAtStr = r['marked_at'] as String?;
        String status = r['status'] as String? ?? 'absent';

        String timeDisplay = '\u2014';
        if (markedAtStr != null) {
          final markedAt = DateTime.parse(markedAtStr).toLocal();
          final hour = markedAt.hour;
          final minute = markedAt.minute.toString().padLeft(2, '0');
          final period = hour >= 12 ? 'PM' : 'AM';
          final displayHour = hour > 12 ? hour - 12 : (hour == 0 ? 12 : hour);
          timeDisplay = '$displayHour:$minute $period';

          // Derive late: present but marked after 9:15 AM
          if (status == 'present') {
            final cutoff = DateTime(
              markedAt.year,
              markedAt.month,
              markedAt.day,
              9,
              15,
            );
            if (markedAt.isAfter(cutoff)) status = 'late';
          }
        }

        // Build dateLabel exactly as hardcoded: Today / Yesterday / Weekday • Mon DD
        final date = DateTime.parse(dateStr);
        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day);
        final yesterday = today.subtract(const Duration(days: 1));
        final recordDay = DateTime(date.year, date.month, date.day);
        final weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
        final months = [
          'Jan',
          'Feb',
          'Mar',
          'Apr',
          'May',
          'Jun',
          'Jul',
          'Aug',
          'Sep',
          'Oct',
          'Nov',
          'Dec',
        ];

        String dateLabel;
        if (recordDay == today) {
          dateLabel = 'Today';
        } else if (recordDay == yesterday) {
          dateLabel = 'Yesterday';
        } else {
          final weekday = weekdays[date.weekday - 1];
          final monthAbbr = months[date.month - 1];
          dateLabel = '$weekday \u2022 $monthAbbr ${date.day}';
        }

        built.add({
          'dateLabel': dateLabel,
          'fullDate': '${months[date.month - 1]} ${date.day}, ${date.year}',
          'time': timeDisplay,
          'status': status,
          'rawDate': dateStr,
        });
      }

      if (mounted) setState(() => _collegeRecords = built);
    } catch (e) {
      debugPrint('[HISTORY] fetchCollegeData error: $e');
    }
  }

  Future<void> _fetchClassData() async {
    try {
      final user = supabase.auth.currentUser;
      if (user == null || _studentClassId == null) return;

      // Fetch finalized sessions with finalized_at for time display
      final sessions = await supabase
          .from('attendance_sessions')
          .select('id, session_date, subject_id, period_id, finalized_at')
          .eq('class_id', _studentClassId!)
          .eq('status', 'finalized')
          .order('finalized_at', ascending: false)
          .limit(200);

      if ((sessions as List).isEmpty) {
        if (mounted) setState(() => _classRecords = []);
        return;
      }

      final sessionIds = sessions.map((s) => s['id'] as String).toList();

      final attendance = await supabase
          .from('period_attendance')
          .select('session_id, status')
          .eq('student_id', user.id)
          .inFilter('session_id', sessionIds);

      final Map<String, String> sessionStatusMap = {};
      for (final a in attendance) {
        sessionStatusMap[a['session_id'] as String] =
            a['status'] as String? ?? 'absent';
      }

      final subjectIds =
          sessions.map((s) => s['subject_id'] as String).toSet().toList();
      final periodIds =
          sessions.map((s) => s['period_id'] as String).toSet().toList();

      final subjectsResp = await supabase
          .from('subjects')
          .select('id, name')
          .inFilter('id', subjectIds);
      final periodsResp = await supabase
          .from('periods')
          .select('id, period_number')
          .inFilter('id', periodIds);

      final Map<String, String> subjectNames = {
        for (final s in subjectsResp) s['id'] as String: s['name'] as String,
      };

      String getOrdinal(int n) {
        if (n >= 11 && n <= 13) return '${n}th';
        switch (n % 10) {
          case 1: return '${n}st';
          case 2: return '${n}nd';
          case 3: return '${n}rd';
          default: return '${n}th';
        }
      }

      final Map<String, String> periodLabels = {
        for (final p in periodsResp)
          p['id'] as String: '${getOrdinal(p['period_number'] as int)} Period',
      };

      final months = ['Jan','Feb','Mar','Apr','May','Jun',
                      'Jul','Aug','Sep','Oct','Nov','Dec'];
      final weekdays = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final yesterday = today.subtract(const Duration(days: 1));

      // Deduplicate: per day, per subject+period combo — keep latest finalized_at
      // Key = "date__subjectId__periodId"
      final Map<String, Map<String, dynamic>> latestMap = {};

      for (final s in sessions) {
        final dateStr = s['session_date'] as String;
        final subjectId = s['subject_id'] as String;
        final periodId = s['period_id'] as String;
        final key = '${dateStr}__${subjectId}__$periodId';

        final existing = latestMap[key];
        final thisFinalized = s['finalized_at'] as String?;

        if (existing == null) {
          latestMap[key] = s;
        } else {
          // Keep the more recently finalized one
          final existingFinalized = existing['finalized_at'] as String?;
          if (thisFinalized != null && existingFinalized != null) {
            if (thisFinalized.compareTo(existingFinalized) > 0) {
              latestMap[key] = s;
            }
          }
        }
      }

      // Build records from deduplicated map
      final List<Map<String, dynamic>> built = [];

      for (final s in latestMap.values) {
        final sessionId = s['id'] as String;
        final dateStr = s['session_date'] as String;
        final finalizedAtStr = s['finalized_at'] as String?;

        final date = DateTime.parse(dateStr);
        final recordDay = DateTime(date.year, date.month, date.day);
        final monthAbbr = months[date.month - 1];

        String dateGroup;
        if (recordDay == today) {
          dateGroup = 'Today \u2022 $monthAbbr ${date.day}, ${date.year}';
        } else if (recordDay == yesterday) {
          dateGroup = 'Yesterday \u2022 $monthAbbr ${date.day}, ${date.year}';
        } else {
          final weekday = weekdays[date.weekday - 1];
          dateGroup = '$weekday \u2022 $monthAbbr ${date.day}, ${date.year}';
        }

        // Format finalized_at as time
        String timeDisplay = '\u2014';
        if (finalizedAtStr != null) {
          final dt = DateTime.parse(finalizedAtStr).toLocal();
          final hour = dt.hour;
          final minute = dt.minute.toString().padLeft(2, '0');
          final ampm = hour >= 12 ? 'PM' : 'AM';
          final displayHour = hour > 12 ? hour - 12 : (hour == 0 ? 12 : hour);
          timeDisplay = '$displayHour:$minute $ampm';
        }

        final status = sessionStatusMap[sessionId] ?? 'absent';
        final subjectName =
            subjectNames[s['subject_id'] as String] ?? 'Unknown';
        final periodLabel =
            periodLabels[s['period_id'] as String] ?? 'Period';

        built.add({
          'dateGroup': dateGroup,
          'subject': subjectName,
          'period': periodLabel,
          'time': timeDisplay,
          'status': status == 'present' ? 'present' : 'absent',
          'rawDate': dateStr,
        });
      }

      // Sort by date descending, then by period label
      built.sort((a, b) {
        final dateCompare =
            (b['rawDate'] as String).compareTo(a['rawDate'] as String);
        if (dateCompare != 0) return dateCompare;
        return (a['period'] as String).compareTo(b['period'] as String);
      });

      if (mounted) setState(() => _classRecords = built);
    } catch (e) {
      debugPrint('[HISTORY] fetchClassData error: $e');
    }
  }

  Future<void> _fetchSubjectData() async {
    try {
      final user = supabase.auth.currentUser;
      if (user == null || _studentClassId == null) return;

      // Step 1: Teacher assignments
      final assignmentsRaw = await supabase
          .from('teacher_assignments')
          .select('subject_id, teacher_id, subjects(id, name, code)')
          .eq('class_id', _studentClassId!);

      final List<Map<String, dynamic>> assignments = (assignmentsRaw as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      if (assignments.isEmpty) {
        if (mounted) setState(() => _subjectRecords = []);
        return;
      }

      // Step 2: Teacher names — via teachers table joining users
      // teachers.id = users.id, so we fetch users directly by teacher_id
      final teacherIds = assignments
          .map((a) => a['teacher_id'] as String?)
          .where((id) => id != null)
          .cast<String>()
          .toSet()
          .toList();

      final Map<String, String> teacherNames = {};
      if (teacherIds.isNotEmpty) {
        final teachersRaw = await supabase
            .rpc('get_teacher_names', params: {'teacher_ids': teacherIds});

        for (final t in (teachersRaw as List)) {
          final id = t['id'] as String?;
          final name = t['full_name'] as String?;
          final title = t['title'] as String? ?? 'Mr';
          if (id != null) teacherNames[id] = '$title. ${name ?? 'Faculty'}';
        }
      }

      // Step 3: ALL finalized sessions for this class
      final sessionsRaw = await supabase
          .from('attendance_sessions')
          .select('id, subject_id')
          .eq('class_id', _studentClassId!)
          .eq('status', 'finalized');

      final List<Map<String, dynamic>> sessions = (sessionsRaw as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      final sessionIds = sessions.map((s) => s['id'] as String).toList();

      // Step 4: Student's period_attendance — ONLY sessions where student has a record
      Map<String, String> sessionStatusMap = {};
      if (sessionIds.isNotEmpty) {
        final attendanceRaw = await supabase
            .from('period_attendance')
            .select('session_id, status')
            .eq('student_id', user.id)
            .inFilter('session_id', sessionIds)
            .inFilter('status', ['present', 'absent']);

        for (final a in (attendanceRaw as List)) {
          final sid = a['session_id'] as String?;
          final st = a['status'] as String?;
          if (sid != null && st != null) sessionStatusMap[sid] = st;
        }
      }

      // Step 5: Build subject records
      // held = sessions where student HAS a period_attendance record (present or absent)
      // attended = sessions where student was present
      final List<Map<String, dynamic>> built = [];

      for (final asgn in assignments) {
        final subjectId = asgn['subject_id'] as String?;
        final teacherId = asgn['teacher_id'] as String?;
        final subjectMap = asgn['subjects'];

        final subjectName = subjectMap is Map
            ? (subjectMap['name'] as String? ?? 'Unknown')
            : 'Unknown';
        final facultyName = teacherId != null
            ? (teacherNames[teacherId] ?? 'Faculty')
            : 'Faculty';

        // Only sessions for this subject
        final subjectSessionIds = sessions
            .where((s) => s['subject_id'] == subjectId)
            .map((s) => s['id'] as String)
            .toList();

        // held = only sessions where student has an attendance record
        final int held = subjectSessionIds
            .where((sid) => sessionStatusMap.containsKey(sid))
            .length;
        final int attended = subjectSessionIds
            .where((sid) => sessionStatusMap[sid] == 'present')
            .length;

        built.add({
          'subject': subjectName,
          'held': held,
          'attended': attended,
          'faculty': facultyName,
        });
      }

      if (mounted) setState(() => _subjectRecords = built);
    } catch (e, st) {
      debugPrint('[SUBJECT] error: $e\n$st');
      if (mounted) setState(() => _subjectRecords = []);
    }
  }

  Future<void> _fetchTimetableData() async {
    try {
      if (_studentClassId == null) return;

      final rows = await supabase
          .from('timetables')
          .select('''
            day_of_week,
            subject_id,
            teacher_id,
            period_id,
            subject:subjects ( name ),
            period:periods ( period_number, start_time, end_time ),
            teachers ( id, title )
          ''')
          .eq('class_id', _studentClassId!)
          .order('day_of_week')
          .order('period_id');

      if ((rows as List).isEmpty) {
        if (mounted) setState(() { _timetableSlots = []; _timetableLoading = false; });
        return;
      }

      // Fetch teacher names
      final teacherIds = rows
          .map((r) => r['teacher_id'] as String)
          .toSet()
          .toList();
      final teacherNamesResp = await supabase
          .rpc('get_teacher_names', params: {'teacher_ids': teacherIds});
      final Map<String, String> teacherFullNames = {};
      final Map<String, String> teacherTitleMap = {};
      for (final t in (teacherNamesResp as List)) {
        final id = t['id'] as String?;
        final name = (t['full_name'] as String?)?.trim() ?? '';
        final title = (t['title'] as String?)?.trim() ?? 'Mr';
        if (id != null && name.isNotEmpty) {
          teacherFullNames[id] = name;
          teacherTitleMap[id] = title;
        }
      }

      final List<Map<String, dynamic>> slots = rows.map<Map<String, dynamic>>((r) {
        final teacherId = r['teacher_id'] as String;
        final title = teacherTitleMap[teacherId] ?? 'Mr';
        final fullName = teacherFullNames[teacherId] ?? '';
        final facultyName = fullName.trim().isNotEmpty ? '$title. $fullName' : 'Faculty';

        final periodNum = (r['period'] as Map?)?['period_number'] as int? ?? 0;
        final startTime = ((r['period'] as Map?)?['start_time'] as String? ?? '').isNotEmpty
            ? ((r['period'] as Map?)?['start_time'] as String).substring(0, 5)
            : '';
        final endTime = ((r['period'] as Map?)?['end_time'] as String? ?? '').isNotEmpty
            ? ((r['period'] as Map?)?['end_time'] as String).substring(0, 5)
            : '';

        return {
          'dayOfWeek': r['day_of_week'] as int,
          'periodNumber': periodNum,
          'startTime': startTime,
          'endTime': endTime,
          'subject': (r['subject'] as Map?)?['name'] as String? ?? 'Unknown',
          'faculty': facultyName,
        };
      }).toList();

      // Sort by day then period
      slots.sort((a, b) {
        final dayComp = (a['dayOfWeek'] as int).compareTo(b['dayOfWeek'] as int);
        if (dayComp != 0) return dayComp;
        return (a['periodNumber'] as int).compareTo(b['periodNumber'] as int);
      });

      if (mounted) setState(() { _timetableSlots = slots; _timetableLoading = false; });
    } catch (e) {
      debugPrint('[TIMETABLE] error: $e');
      if (mounted) setState(() { _timetableLoading = false; });
    }
  }

  void _buildAvailableMonths() {
    final now = DateTime.now();
    final monthAbbrs = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];

    // Collect all dates from college + class records
    final Set<String> allDates = {};
    for (final r in _collegeRecords) {
      allDates.add(r['rawDate'] as String);
    }
    for (final r in _classRecords) {
      allDates.add(r['rawDate'] as String);
    }

    // Group by year → set of month indices (0-based)
    final Map<int, Set<int>> yearMonths = {};
    for (final d in allDates) {
      final date = DateTime.parse(d);
      yearMonths.putIfAbsent(date.year, () => {}).add(date.month - 1);
    }

    // Build available months map — only past/current months
    final Map<int, List<String>> result = {};
    for (final year in yearMonths.keys) {
      final List<String> months = [];
      for (int m = 0; m < 12; m++) {
        final isDataPresent = yearMonths[year]?.contains(m) ?? false;
        final isFuture = DateTime(
          year,
          m + 1,
        ).isAfter(DateTime(now.year, now.month));
        if (isDataPresent && !isFuture) months.add(monthAbbrs[m]);
      }
      if (months.isNotEmpty) result[year] = months;
    }

    if (mounted) {
      setState(() {
        _availableMonths = result;
        // Auto-select latest available month if current selection is not available
        if (result.isNotEmpty) {
          final latestYear = result.keys.reduce((a, b) => a > b ? a : b);
          final monthsForYear = result[latestYear]!;
          if (!result.containsKey(_selectedYear) ||
              !(result[_selectedYear]?.contains(_selectedMonthAbbr) ?? false)) {
            _selectedYear = latestYear;
            _selectedMonthAbbr = monthsForYear.last;
          }
        }
      });
    }
  }

  // Filter helper for month filtering
  List<Map<String, dynamic>> _filterByMonth(
    List<Map<String, dynamic>> records,
  ) {
    return records.where((r) {
      final raw = r['rawDate'] as String?;
      if (raw == null) return false;
      final date = DateTime.parse(raw);
      return date.year == _selectedYear &&
          _monthAbbreviations[date.month - 1] == _selectedMonthAbbr;
    }).toList();
  }

  void _showMonthPicker() {
    setState(() => _sheetOpen = true);
    showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      enableDrag: true,
      builder: (ctx) => _MonthPickerSheet(
        initialYear: _selectedYear,
        initialMonth: _selectedMonthAbbr,
        monthAbbreviations: _monthAbbreviations,
        selectableMonths: _availableMonths,
        availableYears: _availableMonths.keys.toList()..sort(),
      ),
    ).then((result) {
      setState(() => _sheetOpen = false);
      if (result != null) {
        setState(() {
          _selectedYear = result['year'] as int;
          _selectedMonthAbbr = result['month'] as String;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final filteredCollege = _filterByMonth(_collegeRecords);
    final filteredClasses = _filterByMonth(_classRecords);

    final int collegePresentCount = filteredCollege
        .where((e) => e['status'] == 'present' || e['status'] == 'late')
        .length;
    final int collegeTotal = filteredCollege.length;
    final int classPresentCount = filteredClasses
        .where((e) => e['status'] == 'present')
        .length;
    final int classTotal = filteredClasses.length;

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
          toolbarHeight: 64,
          title: FadeTransition(
            opacity: _headerFadeAnim,
            child: SlideTransition(
              position: _headerSlideAnim,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    'History',
                    style: TextStyle(
                      color:
                          theme.textTheme.displayLarge?.color ??
                          AppStyles.textDark,
                      fontWeight: FontWeight.bold,
                      fontSize: 24,
                    ),
                  ),
                  // ── Inline Month Selector ─────────────────────────────
                  GestureDetector(
                    onTapDown: (_) => setState(() => _pillPressed = true),
                    onTapUp: (_) {
                      setState(() => _pillPressed = false);
                      _showMonthPicker();
                    },
                    onTapCancel: () => setState(() => _pillPressed = false),
                    child: AnimatedScale(
                      scale: _pillPressed ? 0.97 : 1.0,
                      duration: const Duration(milliseconds: 120),
                      curve: Curves.easeInOut,
                      child: AnimatedOpacity(
                        opacity: _pillPressed ? 0.90 : 1.0,
                        duration: const Duration(milliseconds: 120),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Text(
                              _selectedMonthLabel,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: isDark
                                    ? Colors.white.withValues(alpha: 0.72)
                                    : AppStyles.textDark.withValues(
                                        alpha: 0.65,
                                      ),
                                height: 1.0,
                              ),
                            ),
                            const SizedBox(width: 2),
                            AnimatedRotation(
                              turns: _sheetOpen ? 0.5 : 0.0,
                              duration: const Duration(milliseconds: 220),
                              curve: Curves.easeInOut,
                              child: Icon(
                                Icons.keyboard_arrow_down_rounded,
                                size: 17,
                                color: isDark
                                    ? Colors.white.withValues(alpha: 0.60)
                                    : AppStyles.textDark.withValues(
                                        alpha: 0.55,
                                      ),
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
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(52),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Container(
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.08)
                      : Colors.black.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
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
                    Tab(text: 'Timetable'),
                  ],
                ),
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
                records: filteredCollege,
              ),
              _ClassAttendanceTab(
                isDark: isDark,
                theme: theme,
                presentCount: classPresentCount,
                totalCount: classTotal,
                records: filteredClasses,
              ),
              _SubjectsTab(
                isDark: isDark,
                theme: theme,
                records: _subjectRecords,
              ),
              _TimetableTab(
                isDark: isDark,
                theme: theme,
                slots: _timetableSlots,
                isLoading: _timetableLoading,
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
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            status == 'absent'
                                ? 'Not marked'
                                : status == 'late'
                                ? 'Late entry'
                                : 'Entered at',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: AppStyles.textGray,
                            ),
                          ),
                          if (status != 'absent') ...[
                            const SizedBox(height: 2),
                            Text(
                              record['time'] as String,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color:
                                    theme.textTheme.displayLarge?.color ??
                                    AppStyles.textDark,
                              ),
                            ),
                          ],
                        ],
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
                  '${record['period']}  •  ${record['time']}',
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

// ─────────────────────────────────────────────────────────────────────────────
// Month Picker Bottom Sheet
// ─────────────────────────────────────────────────────────────────────────────

class _MonthPickerSheet extends StatefulWidget {
  final int initialYear;
  final String initialMonth;
  final List<String> monthAbbreviations;
  final Map<int, List<String>> selectableMonths;
  final List<int> availableYears;

  const _MonthPickerSheet({
    required this.initialYear,
    required this.initialMonth,
    required this.monthAbbreviations,
    required this.selectableMonths,
    required this.availableYears,
  });

  @override
  State<_MonthPickerSheet> createState() => _MonthPickerSheetState();
}

class _MonthPickerSheetState extends State<_MonthPickerSheet>
    with SingleTickerProviderStateMixin {
  late int _activeYear;
  String? _tappedMonth;

  @override
  void initState() {
    super.initState();
    _activeYear = widget.initialYear;
  }

  bool _isSelectable(String month) {
    final selectable = widget.selectableMonths[_activeYear] ?? [];
    return selectable.contains(month);
  }

  void _selectMonth(String month) async {
    if (!_isSelectable(month)) return;
    setState(() => _tappedMonth = month);
    await Future.delayed(const Duration(milliseconds: 160));
    if (mounted) {
      Navigator.of(context).pop({'year': _activeYear, 'month': month});
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF1E1E1E) : Colors.white;
    final handleColor = isDark
        ? Colors.white.withValues(alpha: 0.18)
        : Colors.black.withValues(alpha: 0.13);

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 20),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.10),
            blurRadius: 28,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Drag handle ───────────────────────────────────
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 4),
            child: Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: handleColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          // ── Title ─────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
            child: Row(
              children: [
                Text(
                  'Select Month',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color:
                        theme.textTheme.displayLarge?.color ??
                        AppStyles.textDark,
                  ),
                ),
              ],
            ),
          ),
          // ── Year pill row ──────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
            child: Row(
              children: widget.availableYears.map((year) {
                final isSelected = year == _activeYear;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: GestureDetector(
                    onTap: () => setState(() => _activeYear = year),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeInOut,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? theme.primaryColor
                            : (isDark
                                  ? Colors.white.withValues(alpha: 0.07)
                                  : Colors.black.withValues(alpha: 0.04)),
                        borderRadius: BorderRadius.circular(50),
                        border: Border.all(
                          color: isSelected
                              ? theme.primaryColor
                              : (isDark
                                    ? Colors.white.withValues(alpha: 0.14)
                                    : Colors.black.withValues(alpha: 0.10)),
                          width: 1.5,
                        ),
                      ),
                      child: Text(
                        '$year',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: isSelected
                              ? Colors.white
                              : (isDark
                                    ? Colors.white.withValues(alpha: 0.65)
                                    : AppStyles.textGray),
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          // ── Month grid ────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
            child: GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1.85,
              ),
              itemCount: widget.monthAbbreviations.length,
              itemBuilder: (ctx, i) {
                final month = widget.monthAbbreviations[i];
                final selectable = _isSelectable(month);
                final isCurrentSelected =
                    month == widget.initialMonth &&
                    _activeYear == widget.initialYear;
                final isTapped = _tappedMonth == month;

                return GestureDetector(
                  onTap: selectable ? () => _selectMonth(month) : null,
                  child: AnimatedScale(
                    scale: isTapped ? 0.90 : 1.0,
                    duration: const Duration(milliseconds: 130),
                    curve: Curves.easeInOut,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeInOut,
                      decoration: BoxDecoration(
                        color: isCurrentSelected && selectable
                            ? theme.primaryColor
                            : isTapped
                            ? theme.primaryColor.withValues(alpha: 0.80)
                            : selectable
                            ? (isDark
                                  ? Colors.white.withValues(alpha: 0.07)
                                  : Colors.black.withValues(alpha: 0.04))
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: isCurrentSelected && selectable
                              ? theme.primaryColor
                              : selectable
                              ? (isDark
                                    ? Colors.white.withValues(alpha: 0.12)
                                    : Colors.black.withValues(alpha: 0.09))
                              : Colors.transparent,
                          width: 1,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Opacity(
                        opacity: selectable ? 1.0 : 0.30,
                        child: Text(
                          month,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight:
                                (isCurrentSelected && selectable) || isTapped
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: (isCurrentSelected && selectable) || isTapped
                                ? Colors.white
                                : (isDark
                                      ? Colors.white.withValues(alpha: 0.85)
                                      : AppStyles.textDark),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _TimetableTab extends StatefulWidget {
  final bool isDark;
  final ThemeData theme;
  final List<Map<String, dynamic>> slots;
  final bool isLoading;

  const _TimetableTab({
    required this.isDark,
    required this.theme,
    required this.slots,
    required this.isLoading,
  });

  @override
  State<_TimetableTab> createState() => _TimetableTabState();
}

class _TimetableTabState extends State<_TimetableTab> {
  static const _dayShort = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT'];

  late int _selectedDay;
  late int _previousDay;
  bool _goingForward = true;

  @override
  void initState() {
    super.initState();
    final today = DateTime.now().weekday;
    _selectedDay = today == 7 ? 1 : today;
    _previousDay = _selectedDay;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (widget.slots.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.calendar_month_outlined,
                size: 48, color: AppStyles.textGray.withValues(alpha: 0.4)),
            const SizedBox(height: 12),
            Text('No timetable assigned yet',
                style: TextStyle(
                  fontSize: 14,
                  color: AppStyles.textGray.withValues(alpha: 0.7),
                  fontWeight: FontWeight.w500,
                )),
          ],
        ),
      );
    }

    final Map<int, List<Map<String, dynamic>>> byDay = {};
    for (final slot in widget.slots) {
      final d = slot['dayOfWeek'] as int;
      byDay.putIfAbsent(d, () => []).add(slot);
    }

    final activeDays = [1, 2, 3, 4, 5, 6].where((d) => byDay.containsKey(d)).toList();

    return Column(
      children: [
        // Day selector strip
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: activeDays.map((day) {
                final isSelected = day == _selectedDay;
                final isToday = day == DateTime.now().weekday;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: GestureDetector(
                    onTap: () {
                      if (_selectedDay != day) {
                        setState(() {
                          _previousDay = _selectedDay;
                          _selectedDay = day;
                          _goingForward = day > _previousDay;
                        });
                      }
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeInOut,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                      decoration: BoxDecoration(
                        color: isSelected 
                            ? widget.theme.primaryColor 
                            : (widget.isDark 
                                ? Colors.white.withValues(alpha: 0.07) 
                                : Colors.black.withValues(alpha: 0.05)),
                        borderRadius: BorderRadius.circular(50),
                        border: isSelected 
                            ? null 
                            : Border.all(
                                color: widget.isDark 
                                    ? Colors.white.withValues(alpha: 0.12) 
                                    : Colors.black.withValues(alpha: 0.09),
                                width: 1,
                              ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _dayShort[day - 1],
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                              letterSpacing: isSelected ? 0.6 : 0,
                              color: isSelected 
                                  ? Colors.white 
                                  : (widget.isDark 
                                      ? Colors.white.withValues(alpha: 0.55) 
                                      : AppStyles.textGray),
                            ),
                          ),
                          if (isSelected && isToday) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.25),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text(
                                'TODAY',
                                style: TextStyle(
                                  fontSize: 8,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ),
        
        // Period cards section
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 320),
            transitionBuilder: (child, animation) {
              return FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: _goingForward ? const Offset(0.18, 0) : const Offset(-0.18, 0),
                    end: Offset.zero,
                  ).animate(CurvedAnimation(
                    parent: animation, 
                    curve: Curves.easeOutCubic,
                  )),
                  child: child,
                ),
              );
            },
            child: SingleChildScrollView(
              key: ValueKey(_selectedDay),
              padding: const EdgeInsets.only(left: 20, right: 20, top: 4, bottom: 20),
              child: Column(
                children: (byDay[_selectedDay] ?? []).asMap().entries.map((entry) {
                  final index = entry.key;
                  final slot = entry.value;
                  return FadeSlideY(
                    delay: Duration(milliseconds: 40 + (index * 50)),
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _TimetablePeriodRow(
                        slot: slot,
                        isToday: _selectedDay == DateTime.now().weekday,
                        isDark: widget.isDark,
                        theme: widget.theme,
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _TimetablePeriodRow extends StatefulWidget {
  final Map<String, dynamic> slot;
  final bool isToday;
  final bool isDark;
  final ThemeData theme;

  const _TimetablePeriodRow({
    required this.slot,
    required this.isToday,
    required this.isDark,
    required this.theme,
  });

  @override
  State<_TimetablePeriodRow> createState() => _TimetablePeriodRowState();
}

class _TimetablePeriodRowState extends State<_TimetablePeriodRow> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final int periodNum = widget.slot['periodNumber'] as int;
    final String start = widget.slot['startTime'] as String;
    final String end = widget.slot['endTime'] as String;
    final String subject = widget.slot['subject'] as String;
    final String faculty = widget.slot['faculty'] as String;

    Color accentColor;
    switch (periodNum) {
      case 1: accentColor = widget.theme.primaryColor; break;
      case 2: accentColor = AppStyles.successGreen; break;
      case 3: accentColor = const Color(0xFFF39C12); break;
      case 4: accentColor = const Color(0xFF9B59B6); break;
      case 5: accentColor = AppStyles.errorRed; break;
      default: accentColor = widget.theme.primaryColor; break;
    }

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 130),
        curve: Curves.easeInOut,
        child: Container(
          margin: EdgeInsets.zero,
          decoration: BoxDecoration(
            color: widget.theme.cardTheme.color ?? Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: widget.isDark ? 0.18 : 0.06),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  width: 4,
                  decoration: BoxDecoration(
                    color: accentColor,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(16),
                      bottomLeft: Radius.circular(16),
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      children: [
                        Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: accentColor.withValues(alpha: 0.12),
                            border: Border.all(
                              color: accentColor.withValues(alpha: 0.35),
                              width: 1.5,
                            ),
                          ),
                          child: Center(
                            child: Text(
                              '$periodNum',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                                color: accentColor,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                subject,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: widget.theme.textTheme.displayLarge?.color ?? AppStyles.textDark,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                faculty,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                  color: widget.theme.textTheme.bodyMedium?.color ?? AppStyles.textGray,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              start,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                                color: accentColor,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Container(width: 24, height: 1, color: accentColor.withValues(alpha: 0.4)),
                            const SizedBox(height: 3),
                            Text(
                              end,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                                color: widget.theme.textTheme.bodyMedium?.color ?? AppStyles.textGray,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
