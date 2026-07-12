import 'dart:async';
import 'dart:convert';
import 'dart:math';
// ignore: uri_does_not_exist
import 'package:flutter/material.dart';
// ignore: uri_does_not_exist
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

void main() => runApp(const IntervalApp());

class IntervalApp extends StatelessWidget {
  const IntervalApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Interval Trainer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2962FF),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

// ============================================================
//  隠しメッセージ（合言葉）
// ============================================================
const Map<String, String> kSecretMessages = {
  'やまと': 'お、今日は走るんですね',
  '大和': 'お、今日は走るんですね',
};

// ------------------- 共通フォーマット -------------------
String fmtDur(Duration d) {
  final m = d.inMinutes;
  final s = d.inSeconds % 60;
  final t = (d.inMilliseconds % 1000) ~/ 100;
  return '$m:${s.toString().padLeft(2, '0')}.$t';
}

String fmtSecOnly(Duration d) {
  final m = d.inMinutes;
  final s = d.inSeconds % 60;
  return '$m:${two(s)}';
}

String two(int n) => n.toString().padLeft(2, '0');

const List<Color> kRunnerColors = [
  Color(0xFF42A5F5),
  Color(0xFFFFB74D),
  Color(0xFF66BB6A),
  Color(0xFFBA68C8),
  Color(0xFFEF5350),
  Color(0xFF26C6DA),
];

// ------------------- 保存用データ -------------------
class RunnerRecord {
  final String name;
  final int restSeconds;
  final List<int> lapsMs;

  RunnerRecord({
    required this.name,
    required this.restSeconds,
    required this.lapsMs,
  });

  List<Duration> get laps =>
      lapsMs.map((m) => Duration(milliseconds: m)).toList();

  Duration? get best {
    if (lapsMs.isEmpty) return null;
    return Duration(milliseconds: lapsMs.reduce((a, b) => a < b ? a : b));
  }

  Duration? get avg {
    if (lapsMs.isEmpty) return null;
    final sum = lapsMs.reduce((a, b) => a + b);
    return Duration(milliseconds: sum ~/ lapsMs.length);
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'rest': restSeconds,
        'laps': lapsMs,
      };

  factory RunnerRecord.fromJson(Map<String, dynamic> j) => RunnerRecord(
        name: j['name'],
        restSeconds: j['rest'],
        lapsMs: (j['laps'] as List).map((e) => e as int).toList(),
      );
}

class SessionRecord {
  final DateTime date;
  final int totalSets;
  final List<RunnerRecord> runners;

  SessionRecord({
    required this.date,
    required this.totalSets,
    required this.runners,
  });

  Map<String, dynamic> toJson() => {
        'date': date.toIso8601String(),
        'totalSets': totalSets,
        'runners': runners.map((r) => r.toJson()).toList(),
      };

  factory SessionRecord.fromJson(Map<String, dynamic> j) => SessionRecord(
        date: DateTime.parse(j['date']),
        totalSets: j['totalSets'],
        runners: (j['runners'] as List)
            .map((e) => RunnerRecord.fromJson(e))
            .toList(),
      );

  String get label =>
      '${date.year}/${two(date.month)}/${two(date.day)} ${two(date.hour)}:${two(date.minute)}';
}

class Storage {
  static const _key = 'sessions';

  static Future<List<SessionRecord>> load() async {
    final p = await SharedPreferences.getInstance();
    final list = p.getStringList(_key) ?? [];
    return list.map((s) => SessionRecord.fromJson(jsonDecode(s))).toList();
  }

  static Future<void> save(List<SessionRecord> sessions) async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(
      _key,
      sessions.map((s) => jsonEncode(s.toJson())).toList(),
    );
  }

  static Future<void> saveSettings(
      List<Participant> participants, int totalSets, int commonRest) async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(
      'roster',
      participants
          .map((x) => jsonEncode({'name': x.name, 'rest': x.restSeconds}))
          .toList(),
    );
    await p.setInt('totalSets', totalSets);
    await p.setInt('commonRest', commonRest);
  }

  static Future<Map<String, dynamic>> loadSettings() async {
    final p = await SharedPreferences.getInstance();
    final roster = (p.getStringList('roster') ?? []).map((s) {
      final j = jsonDecode(s);
      return Participant(name: j['name'], restSeconds: j['rest']);
    }).toList();
    return {
      'roster': roster,
      'totalSets': p.getInt('totalSets'),
      'commonRest': p.getInt('commonRest'),
    };
  }
}

String buildShareText(SessionRecord s, {RunnerRecord? only}) {
  final b = StringBuffer();
  b.writeln('Interval Trainer');
  b.writeln(s.label);
  b.writeln('本数: ${s.totalSets}');
  final runners = only != null ? [only] : s.runners;
  for (final r in runners) {
    b.writeln('');
    b.writeln('${r.name}（休憩${r.restSeconds}秒）');
    for (int i = 0; i < r.laps.length; i++) {
      final isBest = r.best != null && r.laps[i] == r.best;
      b.writeln('  ${i + 1}本目: ${fmtDur(r.laps[i])}${isBest ? "  ★ベスト" : ""}');
    }
    if (r.avg != null) b.writeln('  平均: ${fmtDur(r.avg!)}');
  }
  return b.toString();
}

// ------------------- ランタイム用 -------------------
enum RunnerState { running, resting, done }

class Participant {
  String name;
  int restSeconds;

  int currentSet;
  RunnerState state;
  Duration legStart;
  Duration? restEnd;
  final List<Duration> records = [];

  Participant({required this.name, this.restSeconds = 30})
      : currentSet = 1,
        state = RunnerState.running,
        legStart = Duration.zero;

  void resetForSession() {
    currentSet = 1;
    state = RunnerState.running;
    legStart = Duration.zero;
    restEnd = null;
    records.clear();
  }

  Duration? get best {
    if (records.isEmpty) return null;
    return records.reduce((a, b) => a < b ? a : b);
  }

  // 並び替え用スコア：セット数多い順→タイム速い順
  // 「より早く終わっている」= currentSetが大きい、同じなら今本が速い
  int sortScore(Duration elapsed) {
    if (state == RunnerState.done) return -1; // 完了は先頭
    final lapMs =
        state == RunnerState.running ? (elapsed - legStart).inMilliseconds : 0;
    // currentSet大きい順、同じなら経過時間小さい順
    return -(currentSet * 1000000 - lapMs);
  }
}

enum Phase { setup, running, finished }

// ===========================================================
//  Firebase-free リアルタイム同期（jsonbin.io利用）
// ===========================================================
// 無料の https://jsonbin.io を使ってルームの状態を共有する
// APIキー不要のPublic Binを利用
class RoomSync {
  static const _base = 'https://api.jsonbin.io/v3/b';
  // 無料APIキー（jsonbin.io無料アカウントで取得したもの）
  // ★ここに自分のAPIキーを入れてください
  static const _apiKey =
      r'$2a$10$ZWe1L1RhoTk72fJ4ruIycOgMfHwFvDyf5ZwcBsgNlajAuibyUuRjG';

  String? binId;
  String? roomCode;

  // ルーム作成（ホスト側）
  Future<String?> createRoom(Map<String, dynamic> initialState) async {
    try {
      final code = _generateCode();
      final res = await http.post(
        Uri.parse(_base),
        headers: {
          'Content-Type': 'application/json',
          'X-Master-Key': _apiKey,
          'X-Bin-Name': 'room_$code',
          'X-Bin-Private': 'false',
        },
        body: jsonEncode({...initialState, 'roomCode': code}),
      );
      if (res.statusCode == 200 || res.statusCode == 201) {
        final data = jsonDecode(res.body);
        binId = data['metadata']['id'];
        roomCode = code;
        return code;
      }
    } catch (e) {
      debugPrint('createRoom error: $e');
    }
    return null;
  }

  // ルーム参加（ゲスト側）- ルームコードでBin検索
  Future<bool> joinRoom(String code) async {
    try {
      // コードでBinを検索
      final res = await http.get(
        Uri.parse('https://api.jsonbin.io/v3/b?name=room_$code'),
        headers: {'X-Master-Key': _apiKey},
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as List;
        if (data.isNotEmpty) {
          binId = data[0]['id'];
          roomCode = code;
          return true;
        }
      }
    } catch (e) {
      debugPrint('joinRoom error: $e');
    }
    return false;
  }

  // 状態を書き込む
  Future<void> push(Map<String, dynamic> state) async {
    if (binId == null) return;
    try {
      await http.put(
        Uri.parse('$_base/$binId'),
        headers: {
          'Content-Type': 'application/json',
          'X-Master-Key': _apiKey,
        },
        body: jsonEncode({
          ...state,
          'roomCode': roomCode,
          'ts': DateTime.now().millisecondsSinceEpoch
        }),
      );
    } catch (e) {
      debugPrint('push error: $e');
    }
  }

  // 状態を読み込む
  Future<Map<String, dynamic>?> pull() async {
    if (binId == null) return null;
    try {
      final res = await http.get(
        Uri.parse('$_base/$binId/latest'),
        headers: {'X-Master-Key': _apiKey},
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        return data['record'];
      }
    } catch (e) {
      debugPrint('pull error: $e');
    }
    return null;
  }

  String _generateCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rnd = Random.secure();
    return List.generate(4, (_) => chars[rnd.nextInt(chars.length)]).join();
  }

  void dispose() {
    binId = null;
    roomCode = null;
  }
}

// ===========================================================
//  セッション状態のシリアライズ
// ===========================================================
Map<String, dynamic> serializeSession(
    List<Participant> participants, int totalSets, DateTime sessionStart) {
  return {
    'startMs': sessionStart.millisecondsSinceEpoch,
    'totalSets': totalSets,
    'participants': participants
        .map((p) => {
              'name': p.name,
              'restSeconds': p.restSeconds,
              'currentSet': p.currentSet,
              'state': p.state.index,
              'legStartMs': p.legStart.inMilliseconds,
              'restEndMs': p.restEnd?.inMilliseconds,
              'recordsMs': p.records.map((d) => d.inMilliseconds).toList(),
            })
        .toList(),
  };
}

void applyRemoteState(
    List<Participant> participants, Map<String, dynamic> remote) {
  final remotePs = remote['participants'] as List;
  for (int i = 0; i < participants.length && i < remotePs.length; i++) {
    final rp = remotePs[i];
    final p = participants[i];
    // より進んでいる状態を優先して上書き
    final remoteSet = rp['currentSet'] as int;
    final remoteState = RunnerState.values[rp['state'] as int];
    final remoteRecords = (rp['recordsMs'] as List)
        .map((e) => Duration(milliseconds: e as int))
        .toList();

    // ゴール記録が増えていたら更新
    if (remoteRecords.length > p.records.length ||
        (remoteState == RunnerState.done && p.state != RunnerState.done)) {
      p.currentSet = remoteSet;
      p.state = remoteState;
      p.legStart = Duration(milliseconds: rp['legStartMs'] as int);
      p.restEnd = rp['restEndMs'] != null
          ? Duration(milliseconds: rp['restEndMs'] as int)
          : null;
      p.records.clear();
      p.records.addAll(remoteRecords);
    }
  }
}

// ===========================================================
//  HomePage
// ===========================================================
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Phase _phase = Phase.setup;

  int _totalSets = 3;
  int _commonRest = 30;
  final List<Participant> _participants = [
    Participant(name: '参加者１', restSeconds: 30),
    Participant(name: '参加者２', restSeconds: 30),
  ];

  DateTime? _sessionStart;
  Timer? _ticker;
  Timer? _syncTimer;

  List<SessionRecord> _history = [];
  SessionRecord? _currentSession;

  // 同期関連
  final RoomSync _sync = RoomSync();
  bool _isSyncEnabled = false;
  bool _isHost = false;
  String? _roomCode;
  int _lastRemoteTs = 0;
  String _syncStatus = '';

  // 並び替え用
  List<Participant> get _sortedParticipants {
    if (_phase != Phase.running) return _participants;
    final sorted = List<Participant>.from(_participants);
    sorted.sort((a, b) {
      // done は先頭
      if (a.state == RunnerState.done && b.state != RunnerState.done) return -1;
      if (b.state == RunnerState.done && a.state != RunnerState.done) return 1;
      // currentSet 多い順（進んでいる方が先）
      if (b.currentSet != a.currentSet) return b.currentSet - a.currentSet;
      // 同セット数なら今本の経過時間が少ない順（速い方が先）
      final aMs = (a.state == RunnerState.running)
          ? (_elapsed - a.legStart).inMilliseconds
          : 999999999;
      final bMs = (b.state == RunnerState.running)
          ? (_elapsed - b.legStart).inMilliseconds
          : 999999999;
      return aMs - bMs;
    });
    return sorted;
  }

  // 隠し要素
  int _titleTaps = 0;
  DateTime? _lastTitleTap;
  bool _cracked = false;

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _loadSettings();
  }

  Future<void> _loadHistory() async {
    final h = await Storage.load();
    setState(() => _history = h);
  }

  Future<void> _loadSettings() async {
    final data = await Storage.loadSettings();
    final roster = data['roster'] as List<Participant>;
    setState(() {
      if (roster.isNotEmpty) {
        _participants
          ..clear()
          ..addAll(roster);
      }
      if (data['totalSets'] != null) _totalSets = data['totalSets'];
      if (data['commonRest'] != null) _commonRest = data['commonRest'];
    });
  }

  void _saveSettings() {
    Storage.saveSettings(_participants, _totalSets, _commonRest);
  }

  Duration? _historicalBest(Participant p) {
    int? bestMs;
    for (final s in _history) {
      for (final r in s.runners) {
        if (r.name == p.name) {
          for (final v in r.lapsMs) {
            if (bestMs == null || v < bestMs) bestMs = v;
          }
        }
      }
    }
    for (final d in p.records) {
      final v = d.inMilliseconds;
      if (bestMs == null || v < bestMs) bestMs = v;
    }
    if (bestMs == null) return null;
    return Duration(milliseconds: bestMs);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _syncTimer?.cancel();
    super.dispose();
  }

  Duration get _elapsed {
    if (_sessionStart == null) return Duration.zero;
    return DateTime.now().difference(_sessionStart!);
  }

  void _setCommonRest(int seconds) {
    setState(() {
      _commonRest = seconds;
      for (final p in _participants) {
        p.restSeconds = seconds;
      }
    });
    _saveSettings();
  }

  void _startSession() {
    if (_participants.isEmpty) return;
    _saveSettings();
    for (final p in _participants) {
      p.resetForSession();
    }
    _sessionStart = DateTime.now();
    _phase = Phase.running;

    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      _onTick();
    });

    // 同期が有効でホストの場合、初期状態をpush
    if (_isSyncEnabled && _isHost) {
      _pushState();
      _startSyncPoll();
    } else if (_isSyncEnabled && !_isHost) {
      _startSyncPoll();
    }

    setState(() {});
  }

  void _onTick() {
    final elapsed = _elapsed;

    for (final p in _participants) {
      if (p.state == RunnerState.resting && p.restEnd != null) {
        if (elapsed >= p.restEnd!) {
          if (p.currentSet >= _totalSets) {
            p.state = RunnerState.done;
          } else {
            p.currentSet++;
            p.legStart = p.restEnd!;
            p.state = RunnerState.running;
          }
          p.restEnd = null;
          _notify();
        }
      }
    }

    if (_participants.every((p) => p.state == RunnerState.done)) {
      _finishSession();
      return;
    }

    setState(() {});
  }

  void _notify() {
    HapticFeedback.mediumImpact();
    SystemSound.play(SystemSoundType.alert);
  }

  void _goal(Participant p) {
    if (p.state != RunnerState.running) return;
    final elapsed = _elapsed;
    final legTime = elapsed - p.legStart;
    p.records.add(legTime);
    HapticFeedback.lightImpact();

    if (p.currentSet >= _totalSets) {
      p.state = RunnerState.done;
    } else {
      p.restEnd = elapsed + Duration(seconds: p.restSeconds);
      p.state = RunnerState.resting;
    }

    // 同期: ゴール押したら即push
    if (_isSyncEnabled) {
      _pushState();
    }

    setState(() {});
  }

  // ========== 同期処理 ==========

  Future<void> _pushState() async {
    if (_sessionStart == null) return;
    final state = serializeSession(_participants, _totalSets, _sessionStart!);
    await _sync.push(state);
  }

  void _startSyncPoll() {
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      final remote = await _sync.pull();
      if (remote == null) return;
      final ts = remote['ts'] as int? ?? 0;
      if (ts <= _lastRemoteTs) return;
      _lastRemoteTs = ts;

      // ゲスト側のみリモート状態を適用（ホストは自分が正）
      if (!_isHost) {
        setState(() {
          applyRemoteState(_participants, remote);
        });
      } else {
        // ホスト側はゲストのゴールのみ取り込む
        setState(() {
          applyRemoteState(_participants, remote);
        });
      }
    });
  }

  Future<void> _showRoomDialog() async {
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => _RoomDialog(
        onHost: (code) async {
          final state = {
            'startMs': 0,
            'totalSets': _totalSets,
            'participants': _participants
                .map((p) => {
                      'name': p.name,
                      'restSeconds': p.restSeconds,
                      'currentSet': 1,
                      'state': 0,
                      'legStartMs': 0,
                      'restEndMs': null,
                      'recordsMs': [],
                    })
                .toList(),
          };
          final roomCode = await _sync.createRoom(state);
          if (roomCode != null) {
            setState(() {
              _isSyncEnabled = true;
              _isHost = true;
              _roomCode = roomCode;
              _syncStatus = 'ルーム: $roomCode（ホスト）';
            });
            if (context.mounted) Navigator.pop(context, true);
          } else {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('ルーム作成に失敗しました。APIキーを確認してください。')),
              );
            }
          }
        },
        onJoin: (code) async {
          final ok = await _sync.joinRoom(code);
          if (ok) {
            setState(() {
              _isSyncEnabled = true;
              _isHost = false;
              _roomCode = code;
              _syncStatus = 'ルーム: $code（サブ端末）';
            });
            if (context.mounted) Navigator.pop(context, true);
          } else {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('ルームが見つかりません')),
              );
            }
          }
        },
        onCancel: () => Navigator.pop(context),
      ),
    );
  }

  void _disconnectRoom() {
    setState(() {
      _isSyncEnabled = false;
      _isHost = false;
      _roomCode = null;
      _syncStatus = '';
    });
    _syncTimer?.cancel();
    _sync.dispose();
  }

  // ========== セッション管理 ==========

  SessionRecord _snapshot() {
    return SessionRecord(
      date: DateTime.now(),
      totalSets: _totalSets,
      runners: _participants
          .map(
            (p) => RunnerRecord(
              name: p.name,
              restSeconds: p.restSeconds,
              lapsMs: p.records.map((d) => d.inMilliseconds).toList(),
            ),
          )
          .toList(),
    );
  }

  void _finishSession() {
    _ticker?.cancel();
    _syncTimer?.cancel();
    final snap = _snapshot();
    final hasData = snap.runners.any((r) => r.lapsMs.isNotEmpty);
    if (hasData) {
      _history.insert(0, snap);
      Storage.save(_history);
    }
    _currentSession = snap;
    setState(() => _phase = Phase.finished);
  }

  void _finishEarly() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('終了する？'),
        content: const Text('途中までの記録を保存して結果画面にうつります。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('つづける'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              _finishSession();
            },
            child: const Text('終了'),
          ),
        ],
      ),
    );
  }

  void _backToSetup() {
    _ticker?.cancel();
    setState(() => _phase = Phase.setup);
  }

  void _openHistory() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => HistoryPage(
          history: _history,
          onDelete: (i) {
            setState(() => _history.removeAt(i));
            Storage.save(_history);
          },
        ),
      ),
    );
  }

  void _showSecret(String msg) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(msg, style: const TextStyle(fontSize: 18)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('閉じる'),
          ),
        ],
      ),
    );
  }

  void _onTitleTap() {
    final now = DateTime.now();
    if (_lastTitleTap == null ||
        now.difference(_lastTitleTap!) > const Duration(milliseconds: 800)) {
      _titleTaps = 0;
    }
    _lastTitleTap = now;
    _titleTaps++;
    if (_titleTaps >= 7) {
      _titleTaps = 0;
      HapticFeedback.heavyImpact();
      setState(() => _cracked = true);
    }
  }

  void _showHelp() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('使い方'),
        content: const SingleChildScrollView(
          child: Text(
            'このアプリは、複数人で同時にインターバルトレーニングをするためのタイマーです。'
            '全員いっせいにスタートし、各自がゴールした時間を計りながら、'
            'その人ごとの休憩を管理できます。\n\n'
            '■ タイムの見方\n'
            'タイムは「分:秒.コンマ秒」で表示されます。\n'
            '　例）1:05.3 → 1分 5.3秒\n'
            '　　　0:42.0 → 42.0秒\n\n'
            '■ 二端末連動\n'
            '設定画面の「二台で計測」ボタンを押してルームを作成し、\n'
            'もう一台でルームコードを入力すると連動できます。\n'
            '片方でゴールを押すと、もう片方にも反映されます。\n\n'
            '■ 準備\n'
            '・セット数（1人が走る本数）を決めます。\n'
            '・休憩時間を決めます。\n'
            '・参加者を追加します。\n\n'
            '■ トレーニング中\n'
            '・「スタート」で全員いっせいに計測が始まります。\n'
            '・各自ゴールしたら、自分の「ゴール」ボタンを押します。\n'
            '・カードは「進んでいる順」で自動的に並び替わります。\n'
            '・休憩中の秒数をタップすると大きく表示されます。\n\n'
            '■ 結果・記録\n'
            '・「一覧／推移」で表示を切り替えられます。\n'
            '・「全体をコピー」や各人のコピーボタンで記録をコピーできます。\n',
            style: TextStyle(fontSize: 14, height: 1.6),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('閉じる'),
          ),
        ],
      ),
    );
  }

  String _fmtSec(Duration d) {
    final total = (d.inMilliseconds / 1000).ceil();
    return '$total';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: _phase == Phase.setup
            ? IconButton(
                icon: const Icon(Icons.help_outline),
                tooltip: '使い方',
                onPressed: _showHelp,
              )
            : null,
        title: GestureDetector(
          onTap: _onTitleTap,
          child: const Text('Interval Trainer'),
        ),
        centerTitle: true,
        actions: [
          if (_phase == Phase.setup)
            IconButton(
              icon: const Icon(Icons.history),
              tooltip: '履歴',
              onPressed: _openHistory,
            ),
          if (_phase == Phase.running)
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: '終了',
              onPressed: _finishEarly,
            ),
        ],
      ),
      body: Stack(
        children: [
          switch (_phase) {
            Phase.setup => _buildSetup(),
            Phase.running => _buildRunning(),
            Phase.finished => _buildFinished(),
          },
          if (_cracked)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _cracked = false),
                child: CustomPaint(painter: CrackPainter()),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSetup() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 同期ステータスバナー
        if (_isSyncEnabled)
          Card(
            color: Colors.blue.withValues(alpha: 0.2),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  const Icon(Icons.wifi, size: 18, color: Colors.blue),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _syncStatus,
                      style: const TextStyle(fontSize: 14, color: Colors.blue),
                    ),
                  ),
                  if (_isHost)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.blue,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        _roomCode ?? '',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                          letterSpacing: 4,
                        ),
                      ),
                    ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: _disconnectRoom,
                    tooltip: '切断',
                  ),
                ],
              ),
            ),
          ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                const Text('セット数', style: TextStyle(fontSize: 16)),
                const Spacer(),
                IconButton.filledTonal(
                  onPressed: () => setState(() {
                    if (_totalSets > 1) _totalSets--;
                  }),
                  icon: const Icon(Icons.remove),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    '$_totalSets',
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton.filledTonal(
                  onPressed: () => setState(() => _totalSets++),
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '全員の休憩時間\n',
                    style: TextStyle(fontSize: 16),
                  ),
                ),
                IconButton.filledTonal(
                  onPressed: () {
                    if (_commonRest > 5) _setCommonRest(_commonRest - 5);
                  },
                  icon: const Icon(Icons.remove),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    '$_commonRest 秒',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton.filledTonal(
                  onPressed: () => _setCommonRest(_commonRest + 5),
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Text('参加者', style: TextStyle(fontSize: 16)),
        ),
        ..._participants.asMap().entries.map((e) {
          final i = e.key;
          final p = e.value;
          return Card(
            child: ListTile(
              title: Text(p.name, style: const TextStyle(fontSize: 16)),
              subtitle: Text('休憩 ${p.restSeconds} 秒'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.edit),
                    onPressed: () => _editParticipant(i),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () {
                      setState(() => _participants.removeAt(i));
                      _saveSettings();
                    },
                  ),
                ],
              ),
            ),
          );
        }),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => _editParticipant(null),
          icon: const Icon(Icons.person_add),
          label: const Text('参加者を追加'),
        ),
        const SizedBox(height: 12),
        // 二台連動ボタン
        OutlinedButton.icon(
          onPressed: _isSyncEnabled ? null : _showRoomDialog,
          icon: const Icon(Icons.devices),
          label: Text(_isSyncEnabled ? '連動中' : '二台で計測（連動）'),
        ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _participants.isEmpty ? null : _startSession,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 18),
          ),
          child: const Text('スタート', style: TextStyle(fontSize: 18)),
        ),
      ],
    );
  }

  void _editParticipant(int? index) {
    final isNew = index == null;
    final nameCtrl = TextEditingController(
      text: isNew ? '' : _participants[index].name,
    );
    int rest = isNew ? _commonRest : _participants[index].restSeconds;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialog) {
            return AlertDialog(
              title: Text(isNew ? '参加者を追加' : '参加者を編集'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(labelText: '名前'),
                    autofocus: true,
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      const Text('休憩'),
                      const Spacer(),
                      IconButton.filledTonal(
                        onPressed: () => setDialog(() {
                          if (rest > 5) rest -= 5;
                        }),
                        icon: const Icon(Icons.remove),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(
                          '$rest 秒',
                          style: const TextStyle(fontSize: 18),
                        ),
                      ),
                      IconButton.filledTonal(
                        onPressed: () => setDialog(() => rest += 5),
                        icon: const Icon(Icons.add),
                      ),
                    ],
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('キャンセル'),
                ),
                FilledButton(
                  onPressed: () {
                    final name = nameCtrl.text.trim();
                    if (name.isEmpty) return;
                    setState(() {
                      if (isNew) {
                        _participants.add(
                          Participant(name: name, restSeconds: rest),
                        );
                      } else {
                        _participants[index].name = name;
                        _participants[index].restSeconds = rest;
                      }
                    });
                    _saveSettings();
                    Navigator.pop(context);
                    final secret = kSecretMessages[name];
                    if (secret != null) _showSecret(secret);
                  },
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildRunning() {
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 20),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Column(
            children: [
              if (_isSyncEnabled)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.wifi, size: 14, color: Colors.blue),
                      const SizedBox(width: 4),
                      Text(
                        'ルーム: $_roomCode',
                        style:
                            const TextStyle(fontSize: 12, color: Colors.blue),
                      ),
                    ],
                  ),
                ),
              const Text('全体タイム', style: TextStyle(fontSize: 14)),
              const SizedBox(height: 2),
              Text(
                fmtDur(_elapsed),
                style: const TextStyle(
                  fontSize: 48,
                  fontWeight: FontWeight.bold,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: _sortedParticipants.map(_buildRunnerCard).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildRunnerCard(Participant p) {
    final hb = _historicalBest(p);
    Color cardColor;
    Widget trailing;
    String sub;

    switch (p.state) {
      case RunnerState.running:
        cardColor = Theme.of(context).colorScheme.surfaceContainerHigh;
        final lap = _elapsed - p.legStart;
        sub = '${p.currentSet} / $_totalSets 本目  ・  ${fmtDur(lap)}';
        trailing = FilledButton(
          onPressed: () => _goal(p),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          ),
          child: const Text('ゴール', style: TextStyle(fontSize: 16)),
        );
        break;
      case RunnerState.resting:
        cardColor = Colors.orange.withValues(alpha: 0.25);
        final rem = p.restEnd! - _elapsed;
        final remSafe = rem.isNegative ? Duration.zero : rem;
        sub = '次は ${p.currentSet + 1} 本目';
        // ★タップで拡大
        trailing = GestureDetector(
          onTap: () => _showRestCountdown(p, remSafe),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const Text('休憩 (タップで拡大)',
                  style: TextStyle(fontSize: 11, color: Colors.orange)),
              Text(
                '${_fmtSec(remSafe)}秒',
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Colors.orange,
                  decoration: TextDecoration.underline,
                  decorationColor: Colors.orange,
                ),
              ),
            ],
          ),
        );
        break;
      case RunnerState.done:
        cardColor = Colors.green.withValues(alpha: 0.30);
        sub = '$_totalSets 本 完了';
        trailing = const Icon(Icons.check_circle, size: 32);
        break;
    }

    return Card(
      color: cardColor,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    p.name,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(sub, style: const TextStyle(fontSize: 13)),
                  if (hb != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      '★ ベスト ${fmtSecOnly(hb)}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.green.shade300,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            trailing,
          ],
        ),
      ),
    );
  }

  // ★ 休憩カウントダウン 拡大表示
  void _showRestCountdown(Participant p, Duration initial) {
    showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (context) => _RestCountdownDialog(
        participant: p,
        getElapsed: () => _elapsed,
      ),
    );
  }

  Widget _buildFinished() {
    return Column(
      children: [
        Expanded(child: ResultView(session: _currentSession!)),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _backToSetup,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: const Text('設定にもどる'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _startSession,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: const Text('もう一度'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ===========================================================
//  休憩カウントダウン 拡大ダイアログ
// ===========================================================
class _RestCountdownDialog extends StatefulWidget {
  final Participant participant;
  final Duration Function() getElapsed;

  const _RestCountdownDialog({
    required this.participant,
    required this.getElapsed,
  });

  @override
  State<_RestCountdownDialog> createState() => _RestCountdownDialogState();
}

class _RestCountdownDialogState extends State<_RestCountdownDialog> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted) return;
      final p = widget.participant;
      if (p.state != RunnerState.resting) {
        Navigator.of(context).pop();
        return;
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.participant;
    if (p.restEnd == null) return const SizedBox();
    final elapsed = widget.getElapsed();
    final rem = p.restEnd! - elapsed;
    final remSafe = rem.isNegative ? Duration.zero : rem;
    final totalMs = p.restSeconds * 1000;
    final remMs = remSafe.inMilliseconds.clamp(0, totalMs);
    final progress = remMs / totalMs;

    return GestureDetector(
      onTap: () => Navigator.of(context).pop(),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                p.name,
                style: const TextStyle(
                  fontSize: 24,
                  color: Colors.white70,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '休憩',
                style: TextStyle(fontSize: 18, color: Colors.orange),
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: 220,
                height: 220,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: 220,
                      height: 220,
                      child: CircularProgressIndicator(
                        value: progress,
                        strokeWidth: 12,
                        backgroundColor: Colors.white12,
                        valueColor:
                            const AlwaysStoppedAnimation<Color>(Colors.orange),
                      ),
                    ),
                    Text(
                      '${(remMs / 1000).ceil()}',
                      style: const TextStyle(
                        fontSize: 96,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                '秒',
                style: TextStyle(fontSize: 28, color: Colors.white70),
              ),
              const SizedBox(height: 48),
              Text(
                '次は ${p.currentSet + 1} 本目',
                style: const TextStyle(fontSize: 18, color: Colors.white54),
              ),
              const SizedBox(height: 32),
              const Text(
                'タップで閉じる',
                style: TextStyle(fontSize: 14, color: Colors.white30),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ===========================================================
//  ルームダイアログ
// ===========================================================
class _RoomDialog extends StatefulWidget {
  final Future<void> Function(String code) onHost;
  final Future<void> Function(String code) onJoin;
  final VoidCallback onCancel;

  const _RoomDialog({
    required this.onHost,
    required this.onJoin,
    required this.onCancel,
  });

  @override
  State<_RoomDialog> createState() => _RoomDialogState();
}

class _RoomDialogState extends State<_RoomDialog> {
  bool _loading = false;
  final _codeCtrl = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('二台で計測'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'ホスト端末でルームを作成して、\nもう一台でコードを入力して参加します。',
            style: TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 20),
          if (_loading)
            const CircularProgressIndicator()
          else ...[
            FilledButton.icon(
              onPressed: () async {
                setState(() => _loading = true);
                await widget.onHost('');
                setState(() => _loading = false);
              },
              icon: const Icon(Icons.add),
              label: const Text('ルームを作成（ホスト）'),
            ),
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 12),
            TextField(
              controller: _codeCtrl,
              decoration: const InputDecoration(
                labelText: 'ルームコード（4文字）',
                border: OutlineInputBorder(),
              ),
              textCapitalization: TextCapitalization.characters,
              maxLength: 4,
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () async {
                final code = _codeCtrl.text.trim().toUpperCase();
                if (code.length != 4) return;
                setState(() => _loading = true);
                await widget.onJoin(code);
                setState(() => _loading = false);
              },
              icon: const Icon(Icons.login),
              label: const Text('参加する（サブ端末）'),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: widget.onCancel,
          child: const Text('キャンセル'),
        ),
      ],
    );
  }
}

// ===========================================================
//  結果ビュー
// ===========================================================
class ResultView extends StatefulWidget {
  final SessionRecord session;
  const ResultView({super.key, required this.session});

  @override
  State<ResultView> createState() => _ResultViewState();
}

class _ResultViewState extends State<ResultView> {
  int _mode = 0;

  void _copy(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('コピーしました'), duration: Duration(seconds: 1)),
    );
  }

  // 結果をベストタイム順にソート
  List<RunnerRecord> get _sortedRunners {
    final runners = List<RunnerRecord>.from(widget.session.runners);
    runners.sort((a, b) {
      final aMs = a.best?.inMilliseconds ?? 999999999;
      final bMs = b.best?.inMilliseconds ?? 999999999;
      return aMs - bMs;
    });
    return runners;
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(s.label, style: const TextStyle(fontSize: 14)),
        const SizedBox(height: 12),
        Center(
          child: SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('一覧（速い順）')),
              ButtonSegment(value: 1, label: Text('推移')),
            ],
            selected: {_mode},
            onSelectionChanged: (v) => setState(() => _mode = v.first),
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () => _copy(buildShareText(s)),
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('全体をコピー'),
          ),
        ),
        const SizedBox(height: 4),
        if (_mode == 0)
          ..._sortedRunners
              .asMap()
              .entries
              .map((e) => _buildListCard(e.value, e.key))
        else
          _buildTrend(s),
      ],
    );
  }

  Widget _buildListCard(RunnerRecord r, int rank) {
    final best = r.best;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // 順位バッジ
                Container(
                  width: 32,
                  height: 32,
                  margin: const EdgeInsets.only(right: 10),
                  decoration: BoxDecoration(
                    color: rank == 0
                        ? Colors.amber
                        : rank == 1
                            ? Colors.grey.shade400
                            : rank == 2
                                ? Colors.brown.shade300
                                : Colors.white12,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      '${rank + 1}',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: rank < 3 ? Colors.black87 : Colors.white,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    r.name,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy, size: 18),
                  tooltip: 'この人をコピー',
                  onPressed: () =>
                      _copy(buildShareText(widget.session, only: r)),
                ),
              ],
            ),
            if (best != null)
              Row(
                children: [
                  Text(
                    'ベスト ${fmtDur(best)}',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.green.shade300,
                    ),
                  ),
                  const SizedBox(width: 16),
                  if (r.avg != null)
                    Text(
                      '平均 ${fmtDur(r.avg!)}',
                      style: const TextStyle(fontSize: 14),
                    ),
                ],
              ),
            const SizedBox(height: 12),
            if (r.laps.isEmpty)
              const Text('記録なし', style: TextStyle(fontSize: 14))
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (int i = 0; i < r.laps.length; i++)
                    _lapChip(i + 1, r.laps[i], r.laps[i] == best),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _lapChip(int n, Duration t, bool isBest) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: isBest
            ? Colors.green.withValues(alpha: 0.30)
            : Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          Text('$n本目', style: const TextStyle(fontSize: 11)),
          Text(
            fmtDur(t),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget _buildTrend(SessionRecord s) {
    final withData = s.runners.where((r) => r.lapsMs.isNotEmpty).toList();
    if (withData.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: Text('記録なし')),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('上ほど速い（タイムが小さい）', style: TextStyle(fontSize: 12)),
        const SizedBox(height: 8),
        SizedBox(
          height: 260,
          child: CustomPaint(
            painter: TrendPainter(
              runners: withData,
              totalSets: s.totalSets,
              gridColor: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.18),
              textColor: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.7),
            ),
            size: Size.infinite,
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 16,
          runSpacing: 8,
          children: [
            for (int i = 0; i < withData.length; i++)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      color: kRunnerColors[i % kRunnerColors.length],
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(withData[i].name, style: const TextStyle(fontSize: 14)),
                ],
              ),
          ],
        ),
      ],
    );
  }
}

// ------------------- 推移グラフの描画 -------------------
class TrendPainter extends CustomPainter {
  final List<RunnerRecord> runners;
  final int totalSets;
  final Color gridColor;
  final Color textColor;

  TrendPainter({
    required this.runners,
    required this.totalSets,
    required this.gridColor,
    required this.textColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const padL = 52.0, padR = 12.0, padT = 12.0, padB = 28.0;
    final plotW = size.width - padL - padR;
    final plotH = size.height - padT - padB;

    int minV = 1 << 62, maxV = 0;
    for (final r in runners) {
      for (final v in r.lapsMs) {
        if (v < minV) minV = v;
        if (v > maxV) maxV = v;
      }
    }
    if (minV > maxV) return;
    if (minV == maxV) {
      minV -= 1000;
      maxV += 1000;
    }
    final range = (maxV - minV).toDouble();

    double xFor(int setIndex) {
      if (totalSets <= 1) return padL + plotW / 2;
      return padL + plotW * setIndex / (totalSets - 1);
    }

    double yFor(int v) => padT + plotH * (v - minV) / range;

    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;

    const lines = 4;
    for (int i = 0; i <= lines; i++) {
      final y = padT + plotH * i / lines;
      canvas.drawLine(Offset(padL, y), Offset(size.width - padR, y), gridPaint);
      final v = (minV + range * i / lines).round();
      _text(
        canvas,
        fmtDur(Duration(milliseconds: v)),
        Offset(4, y - 6),
        textColor,
        size: 10,
      );
    }

    for (int s = 0; s < totalSets; s++) {
      final x = xFor(s);
      _text(
        canvas,
        '${s + 1}',
        Offset(x - 4, size.height - 18),
        textColor,
        size: 11,
      );
    }

    for (int ri = 0; ri < runners.length; ri++) {
      final r = runners[ri];
      final color = kRunnerColors[ri % kRunnerColors.length];
      final linePaint = Paint()
        ..color = color
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke;
      final dotPaint = Paint()..color = color;

      Path? path;
      for (int i = 0; i < r.lapsMs.length; i++) {
        final o = Offset(xFor(i), yFor(r.lapsMs[i]));
        if (path == null) {
          path = Path()..moveTo(o.dx, o.dy);
        } else {
          path.lineTo(o.dx, o.dy);
        }
        canvas.drawCircle(o, 3.5, dotPaint);
      }
      if (path != null) canvas.drawPath(path, linePaint);
    }
  }

  void _text(Canvas c, String s, Offset o, Color col, {double size = 10}) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(color: col, fontSize: size),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, o);
  }

  @override
  bool shouldRepaint(covariant TrendPainter old) => true;
}

// ------------------- 画面割れ演出の描画 -------------------
class CrackPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height * 0.4);
    final rnd = Random(7);

    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = Colors.black.withValues(alpha: 0.12),
    );

    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.85)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    const mainCount = 10;
    for (int i = 0; i < mainCount; i++) {
      final angle = (i / mainCount) * 2 * pi + rnd.nextDouble() * 0.4;
      final len = size.longestSide * (0.45 + rnd.nextDouble() * 0.45);
      final end = center + Offset(cos(angle), sin(angle)) * len;
      _jagged(canvas, center, end, paint, rnd);

      final branches = 1 + rnd.nextInt(2);
      for (int b = 0; b < branches; b++) {
        final t = 0.3 + rnd.nextDouble() * 0.5;
        final from = Offset.lerp(center, end, t)!;
        final ba = angle + (rnd.nextDouble() - 0.5) * 1.2;
        final bl = len * (0.2 + rnd.nextDouble() * 0.3);
        final bend = from + Offset(cos(ba), sin(ba)) * bl;
        _jagged(canvas, from, bend, paint, rnd);
      }
    }

    canvas.drawCircle(center, 5, Paint()..color = Colors.white);
    canvas.drawCircle(
      center,
      14,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.6)
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );
  }

  void _jagged(Canvas c, Offset a, Offset b, Paint p, Random rnd) {
    const seg = 6;
    final path = Path()..moveTo(a.dx, a.dy);
    final dir = b - a;
    final nx = -dir.dy, ny = dir.dx;
    final nlen = sqrt(nx * nx + ny * ny);
    for (int i = 1; i <= seg; i++) {
      final t = i / seg;
      final base = Offset.lerp(a, b, t)!;
      final off = (rnd.nextDouble() - 0.5) * 16 * (1 - t);
      final point = nlen == 0
          ? base
          : Offset(base.dx + nx / nlen * off, base.dy + ny / nlen * off);
      path.lineTo(point.dx, point.dy);
    }
    c.drawPath(path, p);
  }

  @override
  bool shouldRepaint(covariant CrackPainter old) => false;
}

// ===========================================================
//  履歴画面
// ===========================================================
class HistoryPage extends StatefulWidget {
  final List<SessionRecord> history;
  final void Function(int index) onDelete;
  const HistoryPage({super.key, required this.history, required this.onDelete});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  @override
  Widget build(BuildContext context) {
    final h = widget.history;
    return Scaffold(
      appBar: AppBar(title: const Text('履歴'), centerTitle: true),
      body: h.isEmpty
          ? const Center(child: Text('まだ記録がありません'))
          : ListView.builder(
              itemCount: h.length,
              itemBuilder: (context, i) {
                final s = h[i];
                final names = s.runners.map((r) => r.name).join('、');
                return Dismissible(
                  key: ValueKey('${s.date.toIso8601String()}_$i'),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    color: Colors.red.withValues(alpha: 0.4),
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 20),
                    child: const Icon(Icons.delete),
                  ),
                  onDismissed: (_) {
                    widget.onDelete(i);
                    setState(() {});
                  },
                  child: Card(
                    child: ListTile(
                      title: Text(s.label),
                      subtitle: Text('$names ・ ${s.totalSets}本'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => Scaffold(
                              appBar: AppBar(
                                title: const Text('記録の詳細'),
                                centerTitle: true,
                              ),
                              body: ResultView(session: s),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                );
              },
            ),
    );
  }
}
