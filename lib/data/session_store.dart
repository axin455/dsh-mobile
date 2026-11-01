import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../protocol/models.dart';

/// 本地会话与消息缓存。
///
/// DeepSeek Responses API 是无状态的，会话状态必须由客户端维护；
/// 这里用 sqflite 落盘，不依赖 Host「记住」。
class SessionStore {
  Database? _db;

  Future<Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;
    final path = p.join(await getDatabasesPath(), 'dsh_mobile.db');
    final db = await openDatabase(
      path,
      version: 3,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE sessions (
            session_id TEXT PRIMARY KEY,
            title TEXT NOT NULL DEFAULT '',
            updated_at INTEGER NOT NULL DEFAULT 0,
            running INTEGER NOT NULL DEFAULT 0,
            pinned INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute('''
          CREATE TABLE messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL,
            entry_id TEXT NOT NULL,
            role TEXT NOT NULL,
            text TEXT NOT NULL,
            seq INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL DEFAULT 0,
            prompt_tokens INTEGER,
            completion_tokens INTEGER,
            cached_tokens INTEGER,
            detail INTEGER NOT NULL DEFAULT 0,
            detail_label TEXT NOT NULL DEFAULT '',
            UNIQUE(session_id, entry_id)
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_messages_session ON messages(session_id, seq)',
        );
        await db.execute('''
          CREATE TABLE session_stats (
            session_id TEXT PRIMARY KEY,
            payload TEXT NOT NULL,
            updated_at INTEGER NOT NULL DEFAULT 0
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          // 旧库只有纯文本，补上用量列；历史消息的 token 无法回填，保持 null。
          await db.execute(
            'ALTER TABLE messages ADD COLUMN prompt_tokens INTEGER',
          );
          await db.execute(
            'ALTER TABLE messages ADD COLUMN completion_tokens INTEGER',
          );
          await db.execute(
            'ALTER TABLE messages ADD COLUMN cached_tokens INTEGER',
          );
          await db.execute('''
            CREATE TABLE IF NOT EXISTS session_stats (
              session_id TEXT PRIMARY KEY,
              payload TEXT NOT NULL,
              updated_at INTEGER NOT NULL DEFAULT 0
            )
          ''');
        }
        if (oldVersion < 3) {
          await db.execute(
            'ALTER TABLE messages ADD COLUMN detail INTEGER NOT NULL DEFAULT 0',
          );
          await db.execute(
            "ALTER TABLE messages ADD COLUMN detail_label TEXT NOT NULL DEFAULT ''",
          );
        }
      },
    );
    _db = db;
    return db;
  }

  Future<void> upsertSession(SessionSummary session) async {
    final db = await _open();
    await db.rawInsert(
      '''
      INSERT INTO sessions (session_id, title, updated_at, running, pinned)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(session_id) DO UPDATE SET
        title = CASE
          WHEN excluded.title <> '' THEN excluded.title
          ELSE sessions.title
        END,
        updated_at = MAX(sessions.updated_at, excluded.updated_at),
        running = excluded.running
      ''',
      [
        session.sessionId,
        session.title,
        session.updatedAt,
        session.running ? 1 : 0,
        session.pinned ? 1 : 0,
      ],
    );
  }

  /// 只刷新时间戳：已有标题保持不变，没有会话行时才插入。
  Future<void> touchSession(String sessionId, {int? updatedAt}) async {
    final db = await _open();
    await db.rawInsert(
      '''
      INSERT INTO sessions (session_id, title, updated_at, running, pinned)
      VALUES (?, '', ?, 0, 0)
      ON CONFLICT(session_id) DO UPDATE SET
        updated_at = MAX(sessions.updated_at, excluded.updated_at)
      ''',
      [sessionId, updatedAt ?? DateTime.now().millisecondsSinceEpoch ~/ 1000],
    );
  }

  Future<String?> readSessionTitle(String sessionId) async {
    final db = await _open();
    final rows = await db.query(
      'sessions',
      columns: ['title'],
      where: 'session_id = ?',
      whereArgs: [sessionId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return (rows.first['title'] as String?) ?? '';
  }

  Future<void> replaceSessions(List<SessionSummary> sessions) async {
    final db = await _open();
    await db.transaction((txn) async {
      for (final session in sessions) {
        await txn.rawInsert(
          '''
          INSERT INTO sessions (session_id, title, updated_at, running, pinned)
          VALUES (?, ?, ?, ?, COALESCE((SELECT pinned FROM sessions WHERE session_id = ?), 0))
          ON CONFLICT(session_id) DO UPDATE SET
            title = CASE
              WHEN excluded.title <> '' THEN excluded.title
              ELSE sessions.title
            END,
            updated_at = MAX(sessions.updated_at, excluded.updated_at),
            running = excluded.running
          ''',
          [
            session.sessionId,
            session.title,
            session.updatedAt,
            session.running ? 1 : 0,
            session.sessionId,
          ],
        );
      }
    });
  }

  Future<List<SessionSummary>> listSessions() async {
    final db = await _open();
    final rows = await db.query(
      'sessions',
      orderBy: 'pinned DESC, updated_at DESC',
    );
    return rows
        .map(
          (row) => SessionSummary(
            sessionId: row['session_id'] as String,
            title: (row['title'] as String?) ?? '',
            updatedAt: (row['updated_at'] as int?) ?? 0,
            running: (row['running'] as int? ?? 0) == 1,
            pinned: (row['pinned'] as int? ?? 0) == 1,
          ),
        )
        .toList(growable: false);
  }

  Future<void> renameSession(String sessionId, String title) async {
    final db = await _open();
    await db.update(
      'sessions',
      {'title': title},
      where: 'session_id = ?',
      whereArgs: [sessionId],
    );
  }

  Future<void> setPinned(String sessionId, bool pinned) async {
    final db = await _open();
    await db.update(
      'sessions',
      {'pinned': pinned ? 1 : 0},
      where: 'session_id = ?',
      whereArgs: [sessionId],
    );
  }

  Future<void> deleteSession(String sessionId) async {
    final db = await _open();
    await db.delete(
      'sessions',
      where: 'session_id = ?',
      whereArgs: [sessionId],
    );
    await db.delete(
      'messages',
      where: 'session_id = ?',
      whereArgs: [sessionId],
    );
  }

  Future<void> saveEntry(String sessionId, ChatEntry entry) async {
    final db = await _open();
    await db.rawInsert(
      '''
      INSERT INTO messages (
        session_id, entry_id, role, text, seq, created_at,
        prompt_tokens, completion_tokens, cached_tokens, detail, detail_label
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(session_id, entry_id) DO UPDATE SET
        text = excluded.text,
        seq = excluded.seq,
        prompt_tokens = COALESCE(excluded.prompt_tokens, messages.prompt_tokens),
        completion_tokens = COALESCE(excluded.completion_tokens, messages.completion_tokens),
        cached_tokens = COALESCE(excluded.cached_tokens, messages.cached_tokens),
        detail = excluded.detail,
        detail_label = excluded.detail_label
      ''',
      [
        sessionId,
        entry.id,
        entry.role.name,
        entry.text,
        entry.seq,
        DateTime.now().millisecondsSinceEpoch,
        entry.promptTokens,
        entry.completionTokens,
        entry.cachedTokens,
        entry.detail ? 1 : 0,
        entry.detailLabel,
      ],
    );
  }

  Future<List<ChatEntry>> loadEntries(String sessionId) async {
    final db = await _open();
    final rows = await db.query(
      'messages',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'seq ASC, id ASC',
    );
    return rows
        .map(
          (row) => ChatEntry(
            id: row['entry_id'] as String,
            role: row['role'] == 'user' ? ChatRole.user : ChatRole.assistant,
            text: (row['text'] as String?) ?? '',
            seq: (row['seq'] as int?) ?? 0,
            promptTokens: row['prompt_tokens'] as int?,
            completionTokens: row['completion_tokens'] as int?,
            cachedTokens: row['cached_tokens'] as int?,
            detail: (row['detail'] as int? ?? 0) == 1,
            detailLabel: (row['detail_label'] as String?) ?? '',
          ),
        )
        .toList(growable: false);
  }

  /// 电脑端 `session-stats` 的原始帧：离线打开会话时先用缓存兜底。
  Future<void> saveStats(String sessionId, String payload) async {
    final db = await _open();
    await db.rawInsert(
      '''
      INSERT INTO session_stats (session_id, payload, updated_at)
      VALUES (?, ?, ?)
      ON CONFLICT(session_id) DO UPDATE SET
        payload = excluded.payload,
        updated_at = excluded.updated_at
      ''',
      [sessionId, payload, DateTime.now().millisecondsSinceEpoch],
    );
  }

  Future<String?> loadStats(String sessionId) async {
    final db = await _open();
    final rows = await db.query(
      'session_stats',
      columns: ['payload'],
      where: 'session_id = ?',
      whereArgs: [sessionId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['payload'] as String?;
  }

  Future<void> clearEntries(String sessionId) async {
    final db = await _open();
    await db.delete(
      'messages',
      where: 'session_id = ?',
      whereArgs: [sessionId],
    );
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
