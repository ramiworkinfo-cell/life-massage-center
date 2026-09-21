import 'dart:io';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = AppDb();
  await db.init();
  runApp(LifeMassageApp(db: db));
}

class LifeMassageApp extends StatelessWidget {
  final AppDb db;
  const LifeMassageApp({super.key, required this.db});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'مركز الحياة للمساج',
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
        home: LoginPage(db: db),
      );
}

class AppDb {
  late Database db;

  Future<void> init() async {
    final dir = await getApplicationDocumentsDirectory();
    db = await openDatabase(
      p.join(dir.path, 'life_massage.db'),
      version: 8,
      onCreate: (d, v) async => _createSchema(d),
      onUpgrade: (d, oldV, newV) async {
        if (oldV < 2) {
          await d.execute('ALTER TABLE services ADD COLUMN description TEXT');
          await d.execute('ALTER TABLE therapists ADD COLUMN phone TEXT');
        }
        if (oldV < 3) {
          await d.execute('CREATE TABLE IF NOT EXISTS holidays(id INTEGER PRIMARY KEY AUTOINCREMENT, date TEXT UNIQUE, reason TEXT)');
          await d.execute("INSERT OR IGNORE INTO settings(key,value) VALUES('work_start','09:00')");
          await d.execute("INSERT OR IGNORE INTO settings(key,value) VALUES('work_end','22:00')");
          await d.execute("INSERT OR IGNORE INTO settings(key,value) VALUES('work_days','1,2,3,4,5,6,7')");
        }
        if (oldV < 4) {
          await d.execute('CREATE TABLE IF NOT EXISTS payments(id INTEGER PRIMARY KEY AUTOINCREMENT, booking_id INTEGER, sale_id INTEGER, amount REAL NOT NULL, currency TEXT NOT NULL, method TEXT NOT NULL, reference TEXT, notes TEXT, created_at TEXT, user_id INTEGER)');
          await d.execute("INSERT OR IGNORE INTO settings(key,value) VALUES('default_currency','JOD')");
        }
        if (oldV < 5) {
          await d.execute('ALTER TABLE users ADD COLUMN password_hash TEXT');
          await d.execute('CREATE TABLE IF NOT EXISTS role_permissions(id INTEGER PRIMARY KEY AUTOINCREMENT, role TEXT NOT NULL, permission TEXT NOT NULL, UNIQUE(role, permission))');
          final legacy = await d.query('users', columns: ['id','password'], where: 'password_hash IS NULL OR password_hash=""');
          for (final u in legacy) {
            final pw = u['password']?.toString() ?? '';
            if (pw.isNotEmpty) {
              final hash = sha256.convert(utf8.encode(pw)).toString();
              await d.update('users', {'password_hash': hash}, where: 'id=?', whereArgs: [u['id']]);
            }
          }
          await _seedPermissions(d);
        }
        if (oldV < 6) {
          await d.execute('CREATE TABLE IF NOT EXISTS loyalty_transactions(id INTEGER PRIMARY KEY AUTOINCREMENT, customer_id INTEGER NOT NULL, sale_id INTEGER, points INTEGER NOT NULL, type TEXT NOT NULL, note TEXT, created_at TEXT, user_id INTEGER)');
          await d.execute("INSERT OR IGNORE INTO settings(key,value) VALUES('loyalty_points_per_10','1')");
        }
        if (oldV < 7) {
          await d.execute("INSERT OR IGNORE INTO settings(key,value) VALUES('whatsapp_number','')");
          await d.execute("INSERT OR IGNORE INTO settings(key,value) VALUES('facebook_url','')");
          await d.execute("INSERT OR IGNORE INTO settings(key,value) VALUES('instagram_url','')");
          await d.execute("INSERT OR IGNORE INTO settings(key,value) VALUES('google_maps_url','')");
          await d.execute("INSERT OR IGNORE INTO settings(key,value) VALUES('weather_city','Amman')");
          await d.execute("INSERT OR IGNORE INTO settings(key,value) VALUES('weather_lat','31.9539')");
          await d.execute("INSERT OR IGNORE INTO settings(key,value) VALUES('weather_lon','35.9106')");
          await d.execute("INSERT OR IGNORE INTO settings(key,value) VALUES('last_sync_at','')");
        }
        if (oldV < 8) {
          await d.execute("INSERT OR IGNORE INTO settings(key,value) VALUES('login_failed_count','0')");
          await d.execute("INSERT OR IGNORE INTO settings(key,value) VALUES('login_lockout_until','')");
          await d.execute("INSERT OR IGNORE INTO settings(key,value) VALUES('last_backup_at','')");
        }
      },
    );
  }

  Future<void> _createSchema(DatabaseExecutor d) async {
    await d.execute('CREATE TABLE users(id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT UNIQUE, password TEXT, password_hash TEXT, role TEXT, active INTEGER)');
    await d.execute('CREATE TABLE role_permissions(id INTEGER PRIMARY KEY AUTOINCREMENT, role TEXT NOT NULL, permission TEXT NOT NULL, UNIQUE(role, permission))');
    await d.execute('CREATE TABLE services(id INTEGER PRIMARY KEY AUTOINCREMENT, name_ar TEXT, name_en TEXT, description TEXT, price REAL, duration INTEGER, image TEXT, active INTEGER)');
    await d.execute('CREATE TABLE customers(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, phone TEXT, notes TEXT, points INTEGER DEFAULT 0, created_at TEXT)');
    await d.execute('CREATE TABLE therapists(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, bio TEXT, phone TEXT, image TEXT, active INTEGER)');
    await d.execute('CREATE TABLE bookings(id INTEGER PRIMARY KEY AUTOINCREMENT, customer_id INTEGER, service_id INTEGER, therapist_id INTEGER, start TEXT, end TEXT, status TEXT, deposit REAL, total REAL, notes TEXT, created_at TEXT, user_id INTEGER)');
    await d.execute('CREATE TABLE sales(id INTEGER PRIMARY KEY AUTOINCREMENT, booking_id INTEGER, user_id INTEGER, customer_id INTEGER, total REAL, paid REAL, currency TEXT, created_at TEXT)');
    await d.execute('CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT)');
    await d.execute('CREATE TABLE holidays(id INTEGER PRIMARY KEY AUTOINCREMENT, date TEXT UNIQUE, reason TEXT)');
    await d.execute('CREATE TABLE payments(id INTEGER PRIMARY KEY AUTOINCREMENT, booking_id INTEGER, sale_id INTEGER, amount REAL NOT NULL, currency TEXT NOT NULL, method TEXT NOT NULL, reference TEXT, notes TEXT, created_at TEXT, user_id INTEGER)');
    await d.execute('CREATE TABLE loyalty_transactions(id INTEGER PRIMARY KEY AUTOINCREMENT, customer_id INTEGER NOT NULL, sale_id INTEGER, points INTEGER NOT NULL, type TEXT NOT NULL, note TEXT, created_at TEXT, user_id INTEGER)');
    final adminHash = sha256.convert(utf8.encode('admin')).toString();
    await d.insert('users', {'username': 'admin', 'password': '', 'password_hash': adminHash, 'role': 'manager', 'active': 1});
    await _seedPermissions(d);
    await d.insert('settings', {'key': 'business_name_ar', 'value': 'مركز الحياة للمساج'});
    await d.insert('settings', {'key': 'currencies', 'value': 'JOD,USD,SAR,AED'});
    await d.insert('settings', {'key': 'default_currency', 'value': 'JOD'});
    await d.insert('settings', {'key': 'work_start', 'value': '09:00'});
    await d.insert('settings', {'key': 'work_end', 'value': '22:00'});
    await d.insert('settings', {'key': 'work_days', 'value': '1,2,3,4,5,6,7'});
    await d.insert('settings', {'key': 'loyalty_points_per_10', 'value': '1'});
    await d.insert('settings', {'key': 'whatsapp_number', 'value': ''});
    await d.insert('settings', {'key': 'facebook_url', 'value': ''});
    await d.insert('settings', {'key': 'instagram_url', 'value': ''});
    await d.insert('settings', {'key': 'google_maps_url', 'value': ''});
    await d.insert('settings', {'key': 'weather_city', 'value': 'Amman'});
    await d.insert('settings', {'key': 'weather_lat', 'value': '31.9539'});
    await d.insert('settings', {'key': 'weather_lon', 'value': '35.9106'});
    await d.insert('settings', {'key': 'last_sync_at', 'value': ''});
    await d.insert('settings', {'key': 'login_failed_count', 'value': '0'});
    await d.insert('settings', {'key': 'login_lockout_until', 'value': ''});
    await d.insert('settings', {'key': 'last_backup_at', 'value': ''});
  }

  static const allPermissions = <String>['dashboard.view','services.manage','customers.manage','therapists.manage','bookings.manage','sales.manage','reports.view','settings.manage','users.manage'];
  static const roles = <String>['manager','reception','therapist','accountant'];

  Future<void> _seedPermissions(DatabaseExecutor d) async {
    final manager = allPermissions;
    final reception = ['dashboard.view','services.manage','customers.manage','therapists.manage','bookings.manage','sales.manage'];
    final therapist = ['dashboard.view','customers.manage','bookings.manage'];
    final accountant = ['dashboard.view','sales.manage','reports.view'];
    final map = {'manager': manager, 'reception': reception, 'therapist': therapist, 'accountant': accountant};
    for (final e in map.entries) {
      for (final permission in e.value) {
        await d.insert('role_permissions', {'role': e.key, 'permission': permission}, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    }
  }

  String hashPassword(String value) => sha256.convert(utf8.encode(value)).toString();

  Future<Map<String, Object?>?> login(String u, String pw) async {
    final now = DateTime.now();
    final lock = await getSetting('login_lockout_until', '');
    if (lock.isNotEmpty) {
      final until = DateTime.tryParse(lock);
      if (until != null && now.isBefore(until)) {
        throw Exception('تم إيقاف تسجيل الدخول مؤقتًا بسبب محاولات فاشلة. حاول بعد ${until.difference(now).inSeconds + 1} ثانية.');
      }
      await setSetting('login_lockout_until', '');
      await setSetting('login_failed_count', '0');
    }
    final r = await db.query('users', where: 'username=? AND active=1', whereArgs: [u], limit: 1);
    if (r.isEmpty) { await _recordFailedLogin(); return null; }
    final user = Map<String,Object?>.from(r.first);
    final expected = user['password_hash']?.toString() ?? '';
    final supplied = hashPassword(pw);
    if (expected.isNotEmpty && expected == supplied) { await _resetLoginFailures(); return user; }
    if (user['password']?.toString() == pw && pw.isNotEmpty) {
      await db.update('users', {'password_hash': supplied, 'password': ''}, where: 'id=?', whereArgs: [user['id']]);
      user['password_hash'] = supplied; user['password'] = '';
      await _resetLoginFailures();
      return user;
    }
    await _recordFailedLogin();
    return null;
  }

  Future<void> _recordFailedLogin() async {
    var count = int.tryParse(await getSetting('login_failed_count', '0')) ?? 0;
    count++;
    if (count >= 5) {
      await setSetting('login_failed_count', '0');
      await setSetting('login_lockout_until', DateTime.now().add(const Duration(seconds: 60)).toIso8601String());
    } else {
      await setSetting('login_failed_count', '$count');
    }
  }

  Future<void> _resetLoginFailures() async {
    await setSetting('login_failed_count', '0');
    await setSetting('login_lockout_until', '');
  }

  Future<String> _databasePath() async {
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, 'life_massage.db');
  }

  Future<Directory> _backupDirectory() async {
    final dir = await getApplicationDocumentsDirectory();
    final out = Directory(p.join(dir.path, 'backups'));
    await out.create(recursive: true);
    return out;
  }

  Future<File> createBackup() async {
    await db.execute('PRAGMA wal_checkpoint(FULL)');
    final src = File(await _databasePath());
    if (!await src.exists()) throw Exception('قاعدة البيانات غير موجودة.');
    final dir = await _backupDirectory();
    final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final out = File(p.join(dir.path, 'life_massage_backup_$stamp.db'));
    await src.copy(out.path);
    final bytes = await out.readAsBytes();
    final checksum = sha256.convert(bytes).toString();
    await File('${out.path}.sha256').writeAsString(checksum);
    await setSetting('last_backup_at', DateTime.now().toIso8601String());
    return out;
  }

  Future<List<File>> listBackups() async {
    final dir = await _backupDirectory();
    final files = dir.listSync().whereType<File>().where((f) => p.extension(f.path) == '.db').toList();
    files.sort((a,b) => b.path.compareTo(a.path));
    return files;
  }

  Future<bool> verifyBackup(File file) async {
    final sidecar = File('${file.path}.sha256');
    if (!await sidecar.exists()) return false;
    final expected = (await sidecar.readAsString()).trim();
    final actual = sha256.convert(await file.readAsBytes()).toString();
    return expected == actual;
  }

  Future<void> restoreBackup(File file) async {
    if (!await verifyBackup(file)) throw Exception('فشل التحقق من سلامة النسخة الاحتياطية.');
    final target = File(await _databasePath());
    await db.execute('PRAGMA wal_checkpoint(FULL)');
    await db.close();
    try {
      await file.copy(target.path);
      final wal = File('${target.path}-wal');
      final shm = File('${target.path}-shm');
      if (await wal.exists()) await wal.delete();
      if (await shm.exists()) await shm.delete();
    } finally {
      db = await openDatabase(target.path, version: 8, onCreate: (d,v) async => _createSchema(d), onUpgrade: (d,oldV,newV) async {
        if (oldV < 2) { await d.execute('ALTER TABLE services ADD COLUMN description TEXT'); await d.execute('ALTER TABLE therapists ADD COLUMN phone TEXT'); }
        if (oldV < 3) { await d.execute('CREATE TABLE IF NOT EXISTS holidays(id INTEGER PRIMARY KEY AUTOINCREMENT, date TEXT UNIQUE, reason TEXT)'); await d.execute("INSERT OR IGNORE INTO settings(key,value) VALUES('work_start','09:00')"); await d.execute("INSERT OR IGNORE INTO settings(key,value) VALUES('work_end','22:00')"); await d.execute("INSERT OR IGNORE INTO settings(key,value) VALUES('work_days','1,2,3,4,5,6,7')"); }
        if (oldV < 4) { await d.execute('CREATE TABLE IF NOT EXISTS payments(id INTEGER PRIMARY KEY AUTOINCREMENT, booking_id INTEGER, sale_id INTEGER, amount REAL NOT NULL, currency TEXT NOT NULL, method TEXT NOT NULL, reference TEXT, notes TEXT, created_at TEXT, user_id INTEGER)'); await d.execute("INSERT OR IGNORE INTO settings(key,value) VALUES('default_currency','JOD')"); }
        if (oldV < 5) { await d.execute('ALTER TABLE users ADD COLUMN password_hash TEXT'); await d.execute('CREATE TABLE IF NOT EXISTS role_permissions(id INTEGER PRIMARY KEY AUTOINCREMENT, role TEXT NOT NULL, permission TEXT NOT NULL, UNIQUE(role, permission))'); }
        if (oldV < 6) { await d.execute('CREATE TABLE IF NOT EXISTS loyalty_transactions(id INTEGER PRIMARY KEY AUTOINCREMENT, customer_id INTEGER NOT NULL, sale_id INTEGER, points INTEGER NOT NULL, type TEXT NOT NULL, note TEXT, created_at TEXT, user_id INTEGER)'); await d.execute("INSERT OR IGNORE INTO settings(key,value) VALUES('loyalty_points_per_10','1')"); }
        if (oldV < 7) { await d.execute("INSERT OR IGNORE INTO settings(key,value) VALUES('whatsapp_number','')"); await d.execute("INSERT OR IGNORE INTO settings(key,value) VALUES('facebook_url','')"); await d.execute("INSERT OR IGNORE INTO settings(key,value) VALUES('instagram_url','')"); await d.execute("INSERT OR IGNORE INTO settings(key,value) VALUES('google_maps_url','')"); await d.execute("INSERT OR IGNORE INTO settings(key,value) VALUES('weather_city','Amman')"); await d.execute("INSERT OR IGNORE INTO settings(key,value) VALUES('weather_lat','31.9539')"); await d.execute("INSERT OR IGNORE INTO settings(key,value) VALUES('weather_lon','35.9106')"); await d.execute("INSERT OR IGNORE INTO settings(key,value) VALUES('last_sync_at','')"); }
        if (oldV < 8) { await d.execute("INSERT OR IGNORE INTO settings(key,value) VALUES('login_failed_count','0')"); await d.execute("INSERT OR IGNORE INTO settings(key,value) VALUES('login_lockout_until','')"); await d.execute("INSERT OR IGNORE INTO settings(key,value) VALUES('last_backup_at','')"); }
      });
    }
  }

  Future<bool> hasPermission(int userId, String permission) async {
    final users = await db.query('users', columns: ['role'], where: 'id=? AND active=1', whereArgs: [userId], limit: 1);
    if (users.isEmpty) return false;
    final role = users.first['role']?.toString() ?? '';
    if (role == 'manager') return true;
    final rows = await db.query('role_permissions', where: 'role=? AND permission=?', whereArgs: [role, permission], limit: 1);
    return rows.isNotEmpty;
  }

  Future<List<Map<String,Object?>>> usersList() => db.query('users', orderBy: 'id DESC');
  Future<bool> usernameExists(String username, [int? exceptId]) async {
    final rows = await db.query('users', where: exceptId == null ? 'username=?' : 'username=? AND id<>?', whereArgs: exceptId == null ? [username] : [username, exceptId], limit: 1);
    return rows.isNotEmpty;
  }
  Future<int> saveUser({int? id, required String username, required String password, required String role, required bool active}) async {
    if (username.trim().isEmpty) throw Exception('اسم المستخدم مطلوب.');
    if (id == null && password.isEmpty) throw Exception('كلمة المرور مطلوبة للمستخدم الجديد.');
    if (await usernameExists(username.trim(), id)) throw Exception('اسم المستخدم مستخدم بالفعل.');
    final row = <String,Object?>{'username': username.trim(), 'role': role, 'active': active ? 1 : 0};
    if (password.isNotEmpty) { row['password_hash'] = hashPassword(password); row['password'] = ''; }
    if (id == null) return db.insert('users', row);
    return db.update('users', row, where: 'id=?', whereArgs: [id]);
  }

  Future<void> changeOwnPassword(int userId, String oldPassword, String newPassword) async {
    if (newPassword.length < 6) throw Exception('كلمة المرور الجديدة يجب أن تكون 6 أحرف على الأقل.');
    final rows = await db.query('users', columns: ['password_hash'], where: 'id=? AND active=1', whereArgs: [userId], limit: 1);
    if (rows.isEmpty || rows.first['password_hash']?.toString() != hashPassword(oldPassword)) throw Exception('كلمة المرور الحالية غير صحيحة.');
    await db.update('users', {'password_hash': hashPassword(newPassword), 'password': ''}, where: 'id=?', whereArgs: [userId]);
  }

  Future<List<Map<String, Object?>>> all(String table) => db.query(table, orderBy: 'id DESC');
  Future<int> insert(String table, Map<String, Object?> row) => db.insert(table, row);
  Future<int> update(String table, Map<String, Object?> row, int id) => db.update(table, row, where: 'id=?', whereArgs: [id]);
  Future<int> delete(String table, int id) => db.delete(table, where: 'id=?', whereArgs: [id]);

  Future<String> getSetting(String key, [String fallback = '']) async {
    final rows = await db.query('settings', where: 'key=?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? fallback : (rows.first['value']?.toString() ?? fallback);
  }

  Future<void> setSetting(String key, String value) async {
    await db.insert('settings', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, Object?>>> bookingsFor(DateTime day) => db.rawQuery('''
    SELECT b.*, c.name customer_name, c.phone, s.name_ar service_name, s.duration, t.name therapist_name
    FROM bookings b
    LEFT JOIN customers c ON c.id=b.customer_id
    LEFT JOIN services s ON s.id=b.service_id
    LEFT JOIN therapists t ON t.id=b.therapist_id
    WHERE date(b.start)=date(?) ORDER BY b.start
  ''', [DateFormat('yyyy-MM-dd').format(day)]);

  Future<List<Map<String, Object?>>> customerHistory(int customerId) => db.rawQuery('''
    SELECT b.id, b.start, b.end, b.status, b.total, b.deposit, s.name_ar service_name, t.name therapist_name
    FROM bookings b LEFT JOIN services s ON s.id=b.service_id LEFT JOIN therapists t ON t.id=b.therapist_id
    WHERE b.customer_id=? ORDER BY b.start DESC
  ''', [customerId]);

  Future<String?> validateBooking({required int customerId, required int serviceId, required int therapistId, required DateTime start}) async {
    final services = await db.query('services', where: 'id=? AND active=1', whereArgs: [serviceId], limit: 1);
    if (services.isEmpty) return 'الخدمة غير متاحة.';
    final therapists = await db.query('therapists', where: 'id=? AND active=1', whereArgs: [therapistId], limit: 1);
    if (therapists.isEmpty) return 'المعالج غير متاح أو غير نشط.';
    final duration = (services.first['duration'] as num?)?.toInt() ?? 0;
    if (duration <= 0) return 'مدة الخدمة غير صحيحة.';
    final end = start.add(Duration(minutes: duration));
    final day = DateFormat('yyyy-MM-dd').format(start);
    final holiday = await db.query('holidays', where: 'date=?', whereArgs: [day], limit: 1);
    if (holiday.isNotEmpty) return 'هذا اليوم عطلة: ${holiday.first['reason'] ?? ''}'.trim();
    final workDays = (await getSetting('work_days', '1,2,3,4,5,6,7')).split(',').where((x) => x.isNotEmpty).map(int.parse).toSet();
    if (!workDays.contains(start.weekday)) return 'اليوم خارج أيام العمل.';
    final workStart = _parseClock(await getSetting('work_start', '09:00'));
    final workEnd = _parseClock(await getSetting('work_end', '22:00'));
    final startMinutes = start.hour * 60 + start.minute;
    final endMinutes = end.hour * 60 + end.minute;
    if (startMinutes < workStart || endMinutes > workEnd) return 'الموعد خارج ساعات العمل.';
    if (end.day != start.day) return 'لا يمكن أن تمتد الجلسة إلى يوم آخر.';
    final conflicts = await db.rawQuery('''
      SELECT id FROM bookings
      WHERE therapist_id=? AND status NOT IN ('cancelled','completed')
      AND datetime(start) < datetime(?) AND datetime(end) > datetime(?) LIMIT 1
    ''', [therapistId, end.toIso8601String(), start.toIso8601String()]);
    if (conflicts.isNotEmpty) return 'يوجد تعارض مع موعد آخر لهذا المعالج.';
    return null;
  }

  int _parseClock(String value) {
    final parts = value.split(':');
    if (parts.length != 2) return 0;
    return (int.tryParse(parts[0]) ?? 0) * 60 + (int.tryParse(parts[1]) ?? 0);
  }

  Future<List<Map<String, Object?>>> salesWithDetails() => db.rawQuery('''
    SELECT sa.*, c.name customer_name, b.start booking_start, s.name_ar service_name,
      COALESCE((SELECT SUM(p.amount) FROM payments p WHERE p.sale_id=sa.id),0) paid_total
    FROM sales sa
    LEFT JOIN customers c ON c.id=sa.customer_id
    LEFT JOIN bookings b ON b.id=sa.booking_id
    LEFT JOIN services s ON s.id=b.service_id
    ORDER BY sa.id DESC
  ''');

  Future<List<Map<String, Object?>>> paymentsForSale(int saleId) => db.query('payments', where: 'sale_id=?', whereArgs: [saleId], orderBy: 'id DESC');

  Future<int> createInvoice({required int bookingId, required int userId, required String currency}) async {
    final bookings = await db.query('bookings', where: 'id=?', whereArgs: [bookingId], limit: 1);
    if (bookings.isEmpty) throw Exception('الحجز غير موجود.');
    final b = bookings.first;
    final existing = await db.query('sales', where: 'booking_id=?', whereArgs: [bookingId], limit: 1);
    if (existing.isNotEmpty) return existing.first['id'] as int;
    return db.insert('sales', {
      'booking_id': bookingId, 'user_id': userId, 'customer_id': b['customer_id'],
      'total': ((b['total'] as num?) ?? 0).toDouble(), 'paid': 0.0, 'currency': currency,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  Future<double> salePaid(int saleId) async {
    final r = await db.rawQuery('SELECT COALESCE(SUM(amount),0) paid FROM payments WHERE sale_id=?', [saleId]);
    return ((r.first['paid'] as num?) ?? 0).toDouble();
  }

  Future<int> addPayment({required int saleId, required double amount, required String currency, required String method, required String reference, required String notes, required int userId}) async {
    if (amount <= 0) throw Exception('قيمة الدفعة يجب أن تكون أكبر من صفر.');
    final sales = await db.query('sales', where: 'id=?', whereArgs: [saleId], limit: 1);
    if (sales.isEmpty) throw Exception('الفاتورة غير موجودة.');
    final sale = sales.first;
    if (sale['currency'].toString() != currency) throw Exception('عملة الدفعة يجب أن تطابق عملة الفاتورة.');
    final total = ((sale['total'] as num?) ?? 0).toDouble();
    final paid = await salePaid(saleId);
    final remaining = total - paid;
    if (amount > remaining + 0.0001) throw Exception('قيمة الدفعة أكبر من المبلغ المتبقي.');
    final paymentId = await db.insert('payments', {
      'sale_id': saleId, 'booking_id': sale['booking_id'], 'amount': amount, 'currency': currency,
      'method': method, 'reference': reference, 'notes': notes, 'created_at': DateTime.now().toIso8601String(), 'user_id': userId,
    });
    final newPaid = paid + amount;
    await db.update('sales', {'paid': newPaid}, where: 'id=?', whereArgs: [saleId]);
    if (newPaid >= total - 0.0001) await awardLoyaltyForSale(saleId, userId);
    return paymentId;
  }

  Future<int> loyaltyBalance(int customerId) async {
    final r = await db.rawQuery('SELECT COALESCE(SUM(points),0) balance FROM loyalty_transactions WHERE customer_id=?', [customerId]);
    return ((r.first['balance'] as num?) ?? 0).toInt();
  }

  Future<void> adjustLoyalty({required int customerId, required int points, required String note, required int userId}) async {
    if (points == 0) throw Exception('عدد النقاط يجب ألا يساوي صفرًا.');
    final balance = await loyaltyBalance(customerId);
    if (points < 0 && balance + points < 0) throw Exception('لا يمكن خصم نقاط أكثر من الرصيد الحالي.');
    await db.transaction((txn) async {
      await txn.insert('loyalty_transactions', {'customer_id': customerId, 'points': points, 'type': points > 0 ? 'manual_add' : 'manual_deduct', 'note': note, 'created_at': DateTime.now().toIso8601String(), 'user_id': userId});
      await txn.update('customers', {'points': balance + points}, where: 'id=?', whereArgs: [customerId]);
    });
  }

  Future<void> awardLoyaltyForSale(int saleId, int userId) async {
    final already = await db.query('loyalty_transactions', where: 'sale_id=? AND type=?', whereArgs: [saleId, 'sale_earned'], limit: 1);
    if (already.isNotEmpty) return;
    final saleRows = await db.query('sales', where: 'id=?', whereArgs: [saleId], limit: 1);
    if (saleRows.isEmpty) return;
    final sale = saleRows.first;
    final total = ((sale['total'] as num?) ?? 0).toDouble();
    final rate = double.tryParse(await getSetting('loyalty_points_per_10', '1')) ?? 1;
    final points = (total / 10 * rate).floor();
    if (points <= 0) return;
    final customerId = (sale['customer_id'] as num?)?.toInt();
    if (customerId == null) return;
    final balance = await loyaltyBalance(customerId);
    await db.transaction((txn) async {
      await txn.insert('loyalty_transactions', {'customer_id': customerId, 'sale_id': saleId, 'points': points, 'type': 'sale_earned', 'note': 'نقاط من الفاتورة #$saleId', 'created_at': DateTime.now().toIso8601String(), 'user_id': userId});
      await txn.update('customers', {'points': balance + points}, where: 'id=?', whereArgs: [customerId]);
    });
  }

  Future<List<Map<String,Object?>>> loyaltyHistory(int customerId) => db.query('loyalty_transactions', where: 'customer_id=?', whereArgs: [customerId], orderBy: 'id DESC');

  Future<Map<String,double>> reportTotals(DateTime from, DateTime to) async {
    final rows = await db.rawQuery('SELECT currency, COALESCE(SUM(total),0) total, COALESCE(SUM(paid),0) paid FROM sales WHERE datetime(created_at) >= datetime(?) AND datetime(created_at) < datetime(?) GROUP BY currency', [from.toIso8601String(), to.toIso8601String()]);
    final out=<String,double>{};
    for(final r in rows){ final cur=r['currency'].toString(); out['${cur}_total']=((r['total'] as num?)??0).toDouble(); out['${cur}_paid']=((r['paid'] as num?)??0).toDouble(); }
    return out;
  }

  Future<List<Map<String,Object?>>> reportByService(DateTime from, DateTime to) => db.rawQuery('''
    SELECT COALESCE(s.name_ar,'غير معروف') service_name, COUNT(sa.id) count, COALESCE(SUM(sa.total),0) total
    FROM sales sa LEFT JOIN bookings b ON b.id=sa.booking_id LEFT JOIN services s ON s.id=b.service_id
    WHERE datetime(sa.created_at) >= datetime(?) AND datetime(sa.created_at) < datetime(?)
    GROUP BY s.id ORDER BY total DESC
  ''', [from.toIso8601String(), to.toIso8601String()]);

  Future<List<Map<String,Object?>>> reportByTherapist(DateTime from, DateTime to) => db.rawQuery('''
    SELECT COALESCE(t.name,'غير معروف') therapist_name, COUNT(b.id) count, COALESCE(SUM(b.total),0) total
    FROM bookings b LEFT JOIN therapists t ON t.id=b.therapist_id
    WHERE datetime(b.start) >= datetime(?) AND datetime(b.start) < datetime(?) AND b.status <> 'cancelled'
    GROUP BY t.id ORDER BY total DESC
  ''', [from.toIso8601String(), to.toIso8601String()]);

  Future<List<Map<String,Object?>>> reportByPaymentMethod(DateTime from, DateTime to) => db.rawQuery('''
    SELECT method, currency, COUNT(id) count, COALESCE(SUM(amount),0) total
    FROM payments WHERE datetime(created_at) >= datetime(?) AND datetime(created_at) < datetime(?)
    GROUP BY method, currency ORDER BY total DESC
  ''', [from.toIso8601String(), to.toIso8601String()]);

  Future<int> reportCustomersCount(DateTime from, DateTime to) async {
    final r=await db.rawQuery('SELECT COUNT(DISTINCT customer_id) count FROM sales WHERE datetime(created_at) >= datetime(?) AND datetime(created_at) < datetime(?)',[from.toIso8601String(),to.toIso8601String()]);
    return ((r.first['count'] as num?)??0).toInt();
  }

  Future<int> createBooking({required int customerId, required int serviceId, required int therapistId, required DateTime start, required String notes, required int userId}) async {
    final error = await validateBooking(customerId: customerId, serviceId: serviceId, therapistId: therapistId, start: start);
    if (error != null) throw Exception(error);
    final service = (await db.query('services', where: 'id=?', whereArgs: [serviceId], limit: 1)).first;
    final total = ((service['price'] as num?) ?? 0).toDouble();
    final duration = ((service['duration'] as num?) ?? 0).toInt();
    final end = start.add(Duration(minutes: duration));
    return db.insert('bookings', {
      'customer_id': customerId,
      'service_id': serviceId,
      'therapist_id': therapistId,
      'start': start.toIso8601String(),
      'end': end.toIso8601String(),
      'status': 'confirmed',
      'deposit': total * 0.5,
      'total': total,
      'notes': notes,
      'created_at': DateTime.now().toIso8601String(),
      'user_id': userId,
    });
  }
}

class LoginPage extends StatefulWidget {
  final AppDb db;
  const LoginPage({super.key, required this.db});
  @override State<LoginPage> createState() => _LoginPageState();
}
class _LoginPageState extends State<LoginPage> {
  final u = TextEditingController(text: 'admin');
  final pw = TextEditingController(text: 'admin');
  bool busy = false; String? err;
  Future<void> go() async {
    setState(() => busy = true);
    final r = await widget.db.login(u.text.trim(), pw.text);
    if (!mounted) return;
    if (r == null) setState(() => err = 'بيانات الدخول غير صحيحة');
    else Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => HomePage(db: widget.db, user: r)));
    setState(() => busy = false);
  }
  @override Widget build(BuildContext c) => Directionality(textDirection: TextDirection.rtl, child: Scaffold(body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: Padding(padding: const EdgeInsets.all(24), child: Card(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.spa, size: 64), const SizedBox(height: 12), const Text('مركز الحياة للمساج', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)), const SizedBox(height: 24), TextField(controller: u, decoration: const InputDecoration(labelText: 'اسم المستخدم')), TextField(controller: pw, obscureText: true, decoration: const InputDecoration(labelText: 'كلمة المرور')), if (err != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(err!, style: const TextStyle(color: Colors.red))), const SizedBox(height: 20), FilledButton(onPressed: busy ? null : go, child: Text(busy ? '...' : 'دخول')), const SizedBox(height: 8), const Text('التجربة الأولى: admin / admin')]))))))));
}

class HomePage extends StatefulWidget {
  final AppDb db; final Map<String, Object?> user;
  const HomePage({super.key, required this.db, required this.user});
  @override State<HomePage> createState() => _HomePageState();
}
class _HomePageState extends State<HomePage> {
  int tab = 0;
  final titles = ['الرئيسية', 'الخدمات', 'العملاء', 'المعالجون', 'الحجوزات', 'المبيعات', 'التقارير', 'الإعدادات', 'المستخدمون'];
  final permissions = ['dashboard.view','services.manage','customers.manage','therapists.manage','bookings.manage','sales.manage','reports.view','settings.manage','users.manage'];
  int get userId => (widget.user['id'] as num?)?.toInt() ?? 1;
  Future<bool> allowed(int index) => widget.db.hasPermission(userId, permissions[index]);
  Widget body() {
    switch (tab) {
      case 1: return ServicesPage(db: widget.db);
      case 2: return CustomersPage(db: widget.db);
      case 3: return TherapistsPage(db: widget.db);
      case 4: return BookingsPage(db: widget.db, userId: userId);
      case 5: return SalesPage(db: widget.db, userId: userId);
      case 6: return ReportsPage(db: widget.db);
      case 7: return SettingsPage(db: widget.db, userId: userId);
      case 8: return UsersPage(db: widget.db, currentUserId: userId);
      default: return Dashboard(db: widget.db);
    }
  }
  @override Widget build(BuildContext c) => Directionality(textDirection: TextDirection.rtl, child: Scaffold(
    appBar: AppBar(title: Text(titles[tab]), actions: [Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Center(child: Text('${widget.user['username']} — ${widget.user['role']}')))]),
    drawer: Drawer(child: FutureBuilder<List<bool>>(future: Future.wait(permissions.map((p) => widget.db.hasPermission(userId, p))), builder: (ctx, snap) {
      final can = snap.data ?? List.filled(titles.length, false);
      return ListView(children: [const DrawerHeader(child: Center(child: Text('مركز الحياة للمساج', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)))),
        for (int i = 0; i < titles.length; i++) if (can[i]) ListTile(selected: tab == i, leading: Icon([Icons.home, Icons.spa, Icons.people, Icons.medical_services, Icons.calendar_month, Icons.point_of_sale, Icons.bar_chart, Icons.settings, Icons.manage_accounts][i]), title: Text(titles[i]), onTap: () { setState(() => tab = i); Navigator.pop(c); }),
        ListTile(leading: const Icon(Icons.logout), title: const Text('خروج'), onTap: () => Navigator.pushReplacement(c, MaterialPageRoute(builder: (_) => LoginPage(db: widget.db))))]);
    })),
    body: FutureBuilder<bool>(future: allowed(tab), builder: (ctx, snap) { if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator()); return snap.data == true ? body() : const Center(child: Text('ليس لديك صلاحية للوصول إلى هذه الصفحة.')); })
  ));
}

class Dashboard extends StatelessWidget {
  final AppDb db; const Dashboard({super.key, required this.db});
  @override Widget build(BuildContext c) => FutureBuilder(future: db.bookingsFor(DateTime.now()), builder: (c, s) { final rows = s.data ?? []; return Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [Text(DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now()), style: const TextStyle(fontSize: 18)), const SizedBox(height: 16), Wrap(spacing: 12, runSpacing: 12, children: [StatCard(title: 'مواعيد اليوم', value: '${rows.length}', icon: Icons.calendar_today), StatCard(title: 'الخدمات', value: 'إدارة', icon: Icons.spa), StatCard(title: 'العملاء', value: 'إدارة', icon: Icons.people), StatCard(title: 'المعالجون', value: 'إدارة', icon: Icons.medical_services)]), const SizedBox(height: 20), const Text('المواعيد الحالية', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)), Expanded(child: ListView(children: rows.map((r) => ListTile(title: Text('${r['service_name'] ?? ''} - ${r['customer_name'] ?? ''}'), subtitle: Text('${r['start'] ?? ''} → ${r['end'] ?? ''} | المعالج: ${r['therapist_name'] ?? ''}'), leading: const Icon(Icons.spa))).toList()))])); });
}
class StatCard extends StatelessWidget { final String title, value; final IconData icon; const StatCard({super.key, required this.title, required this.value, required this.icon}); @override Widget build(BuildContext c) => SizedBox(width: 220, child: Card(child: Padding(padding: const EdgeInsets.all(18), child: Row(children: [Icon(icon, size: 36), const SizedBox(width: 12), Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title), Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold))])])))); }

class ServicesPage extends StatefulWidget { final AppDb db; const ServicesPage({super.key, required this.db}); @override State<ServicesPage> createState() => _ServicesPageState(); }
class _ServicesPageState extends State<ServicesPage> {
  String query = '';
  Future<List<Map<String, Object?>>> f() async { final rows = await widget.db.all('services'); return rows.where((r) => '${r['name_ar']} ${r['name_en']}'.toLowerCase().contains(query.toLowerCase())).toList(); }
  Future<String?> _pickImage() async { final x = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 80); if (x == null) return null; final dir = await getApplicationDocumentsDirectory(); final images = Directory(p.join(dir.path, 'service_images')); await images.create(recursive: true); final target = p.join(images.path, '${DateTime.now().millisecondsSinceEpoch}${p.extension(x.path)}'); await File(x.path).copy(target); return target; }
  Future<void> edit([Map<String, Object?>? old]) async {
    final n = TextEditingController(text: old?['name_ar']?.toString() ?? ''), e = TextEditingController(text: old?['name_en']?.toString() ?? ''), desc = TextEditingController(text: old?['description']?.toString() ?? ''), price = TextEditingController(text: old?['price']?.toString() ?? ''), dur = TextEditingController(text: old?['duration']?.toString() ?? '60'); String? image = old?['image']?.toString();
    await showDialog(context: context, builder: (_) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(title: Text(old == null ? 'إضافة خدمة' : 'تعديل الخدمة'), content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [TextField(controller: n, decoration: const InputDecoration(labelText: 'الاسم بالعربية')), TextField(controller: e, decoration: const InputDecoration(labelText: 'English name')), TextField(controller: desc, decoration: const InputDecoration(labelText: 'وصف الخدمة')), TextField(controller: price, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'السعر')), TextField(controller: dur, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'المدة بالدقائق')), const SizedBox(height: 12), if (image != null && image!.isNotEmpty) Image.file(File(image!), height: 90, errorBuilder: (_, __, ___) => const SizedBox.shrink()), OutlinedButton.icon(onPressed: () async { final picked = await _pickImage(); if (picked != null) setD(() => image = picked); }, icon: const Icon(Icons.image), label: const Text('إضافة/تغيير الصورة'))])), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')), FilledButton(onPressed: () async { final row = {'name_ar': n.text.trim(), 'name_en': e.text.trim(), 'description': desc.text.trim(), 'price': double.tryParse(price.text) ?? 0, 'duration': int.tryParse(dur.text) ?? 60, 'image': image ?? '', 'active': 1}; if (n.text.trim().isEmpty) return; if (old == null) await widget.db.insert('services', row); else await widget.db.update('services', row, old['id'] as int); if (ctx.mounted) Navigator.pop(ctx); setState(() {}); }, child: const Text('حفظ'))]));
  }
  @override Widget build(BuildContext c) => Column(children: [Padding(padding: const EdgeInsets.fromLTRB(12, 12, 12, 4), child: Row(children: [Expanded(child: TextField(onChanged: (v) => setState(() => query = v), decoration: const InputDecoration(prefixIcon: Icon(Icons.search), labelText: 'بحث عن خدمة', border: OutlineInputBorder()))), const SizedBox(width: 8), FilledButton.icon(onPressed: () => edit(), icon: const Icon(Icons.add), label: const Text('إضافة'))])), Expanded(child: FutureBuilder(future: f(), builder: (c, s) { final rows = s.data ?? []; return ListView.builder(itemCount: rows.length, itemBuilder: (_, i) { final r = rows[i]; return Card(child: ListTile(leading: r['image'] != null && r['image'].toString().isNotEmpty ? Image.file(File(r['image'].toString()), width: 56, height: 56, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.spa)) : const Icon(Icons.spa), title: Text('${r['name_ar']} / ${r['name_en']}'), subtitle: Text('${r['price']} | ${r['duration']} دقيقة\n${r['description'] ?? ''}'), isThreeLine: true, trailing: Wrap(children: [IconButton(icon: const Icon(Icons.edit), onPressed: () => edit(r)), IconButton(icon: const Icon(Icons.delete), onPressed: () async { await widget.db.delete('services', r['id'] as int); setState(() {}); })]))); }); }))]);
}

class CustomersPage extends StatefulWidget { final AppDb db; const CustomersPage({super.key, required this.db}); @override State<CustomersPage> createState() => _CustomersPageState(); }
class _CustomersPageState extends State<CustomersPage> {
  String query = '';
  Future<List<Map<String, Object?>>> f() async { final rows = await widget.db.all('customers'); return rows.where((r) => '${r['name']} ${r['phone']}'.toLowerCase().contains(query.toLowerCase())).toList(); }
  Future<void> edit([Map<String, Object?>? old]) async { final n = TextEditingController(text: old?['name']?.toString() ?? ''), ph = TextEditingController(text: old?['phone']?.toString() ?? ''), m = TextEditingController(text: old?['notes']?.toString() ?? ''); await showDialog(context: context, builder: (ctx) => AlertDialog(title: Text(old == null ? 'عميل جديد' : 'تعديل العميل'), content: Column(mainAxisSize: MainAxisSize.min, children: [TextField(controller: n, decoration: const InputDecoration(labelText: 'الاسم')), TextField(controller: ph, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'رقم الهاتف')), TextField(controller: m, maxLines: 3, decoration: const InputDecoration(labelText: 'ملاحظات'))]), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')), FilledButton(onPressed: () async { final row = {'name': n.text.trim(), 'phone': ph.text.trim(), 'notes': m.text.trim(), 'points': old?['points'] ?? 0, 'created_at': old?['created_at'] ?? DateTime.now().toIso8601String()}; if (n.text.trim().isEmpty) return; if (old == null) await widget.db.insert('customers', row); else await widget.db.update('customers', row, old['id'] as int); if (ctx.mounted) Navigator.pop(ctx); setState(() {}); }, child: const Text('حفظ'))])); }
  Future<void> history(Map<String, Object?> customer) async { final rows = await widget.db.customerHistory(customer['id'] as int); if (!mounted) return; await showDialog(context: context, builder: (_) => AlertDialog(title: Text('سجل ${customer['name']}'), content: SizedBox(width: 520, height: 400, child: rows.isEmpty ? const Center(child: Text('لا يوجد سجل حجوزات')) : ListView(children: rows.map((r) => ListTile(title: Text('${r['service_name'] ?? ''}'), subtitle: Text('${r['start']}\nالمعالج: ${r['therapist_name'] ?? ''}\nالحالة: ${r['status']} | الإجمالي: ${r['total']} | العربون: ${r['deposit']}'), isThreeLine: true)).toList())), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('إغلاق'))])); }
  Future<void> loyalty(Map<String,Object?> customer) async {
    final id=customer['id'] as int; final points=await widget.db.loyaltyBalance(id); final value=TextEditingController(); final note=TextEditingController();
    await showDialog(context:context,builder:(ctx)=>AlertDialog(title:Text('نقاط الولاء — ${customer['name']}'),content:Column(mainAxisSize:MainAxisSize.min,children:[Text('الرصيد الحالي: $points نقطة'),TextField(controller:value,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'عدد النقاط (موجب إضافة / سالب خصم)')),TextField(controller:note,decoration:const InputDecoration(labelText:'ملاحظة'))]),actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),FilledButton(onPressed:()async{try{await widget.db.adjustLoyalty(customerId:id,points:int.tryParse(value.text.trim())??0,note:note.text.trim(),userId:1);if(ctx.mounted)Navigator.pop(ctx);if(mounted)setState((){});}catch(e){ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.toString().replaceFirst('Exception: ',''))));}},child:const Text('حفظ'))]));
  }

  @override Widget build(BuildContext c) => Column(children: [Padding(padding: const EdgeInsets.all(12), child: Row(children: [Expanded(child: TextField(onChanged: (v) => setState(() => query = v), decoration: const InputDecoration(prefixIcon: Icon(Icons.search), labelText: 'بحث بالاسم أو الهاتف', border: OutlineInputBorder()))), const SizedBox(width: 8), FilledButton.icon(onPressed: () => edit(), icon: const Icon(Icons.person_add), label: const Text('إضافة'))])), Expanded(child: FutureBuilder(future: f(), builder: (c, s) { final rows = s.data ?? []; return ListView(children: rows.map((r) => Card(child: ListTile(title: Text('${r['name']}'), subtitle: Text('${r['phone']} | نقاط الولاء: ${r['points']}\n${r['notes'] ?? ''}'), isThreeLine: true, trailing: Wrap(children: [IconButton(tooltip: 'الولاء', icon: const Icon(Icons.stars), onPressed: () => loyalty(r)), IconButton(tooltip: 'السجل', icon: const Icon(Icons.history), onPressed: () => history(r)), IconButton(icon: const Icon(Icons.edit), onPressed: () => edit(r)), IconButton(icon: const Icon(Icons.delete), onPressed: () async { await widget.db.delete('customers', r['id'] as int); setState(() {}); })])))).toList()); }))]);
}

class TherapistsPage extends StatefulWidget { final AppDb db; const TherapistsPage({super.key, required this.db}); @override State<TherapistsPage> createState() => _TherapistsPageState(); }
class _TherapistsPageState extends State<TherapistsPage> {
  String query = '';
  Future<List<Map<String, Object?>>> f() async { final rows = await widget.db.all('therapists'); return rows.where((r) => '${r['name']} ${r['bio']} ${r['phone']}'.toLowerCase().contains(query.toLowerCase())).toList(); }
  Future<String?> _pickImage() async { final x = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 80); if (x == null) return null; final dir = await getApplicationDocumentsDirectory(); final images = Directory(p.join(dir.path, 'therapist_images')); await images.create(recursive: true); final target = p.join(images.path, '${DateTime.now().millisecondsSinceEpoch}${p.extension(x.path)}'); await File(x.path).copy(target); return target; }
  Future<void> edit([Map<String, Object?>? old]) async { final n = TextEditingController(text: old?['name']?.toString() ?? ''), ph = TextEditingController(text: old?['phone']?.toString() ?? ''), bio = TextEditingController(text: old?['bio']?.toString() ?? ''); String? image = old?['image']?.toString(); await showDialog(context: context, builder: (_) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(title: Text(old == null ? 'إضافة معالج' : 'تعديل المعالج'), content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [TextField(controller: n, decoration: const InputDecoration(labelText: 'اسم المعالج')), TextField(controller: ph, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'رقم الهاتف')), TextField(controller: bio, maxLines: 4, decoration: const InputDecoration(labelText: 'التعريف والخبرة')), if (image != null && image!.isNotEmpty) Image.file(File(image!), height: 100, errorBuilder: (_, __, ___) => const SizedBox.shrink()), OutlinedButton.icon(onPressed: () async { final picked = await _pickImage(); if (picked != null) setD(() => image = picked); }, icon: const Icon(Icons.image), label: const Text('إضافة/تغيير الصورة'))])), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')), FilledButton(onPressed: () async { if (n.text.trim().isEmpty) return; final row = {'name': n.text.trim(), 'phone': ph.text.trim(), 'bio': bio.text.trim(), 'image': image ?? '', 'active': 1}; if (old == null) await widget.db.insert('therapists', row); else await widget.db.update('therapists', row, old['id'] as int); if (ctx.mounted) Navigator.pop(ctx); setState(() {}); }, child: const Text('حفظ'))])); }
  @override Widget build(BuildContext c) => Column(children: [Padding(padding: const EdgeInsets.all(12), child: Row(children: [Expanded(child: TextField(onChanged: (v) => setState(() => query = v), decoration: const InputDecoration(prefixIcon: Icon(Icons.search), labelText: 'بحث عن معالج', border: OutlineInputBorder()))), const SizedBox(width: 8), FilledButton.icon(onPressed: () => edit(), icon: const Icon(Icons.add), label: const Text('إضافة'))])), Expanded(child: FutureBuilder(future: f(), builder: (c, s) { final rows = s.data ?? []; return ListView.builder(itemCount: rows.length, itemBuilder: (_, i) { final r = rows[i]; return Card(child: ListTile(leading: r['image'] != null && r['image'].toString().isNotEmpty ? Image.file(File(r['image'].toString()), width: 56, height: 56, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.person)) : const Icon(Icons.person), title: Text('${r['name']}'), subtitle: Text('${r['phone'] ?? ''}\n${r['bio'] ?? ''}'), isThreeLine: true, trailing: Wrap(children: [IconButton(icon: const Icon(Icons.edit), onPressed: () => edit(r)), IconButton(icon: const Icon(Icons.delete), onPressed: () async { await widget.db.delete('therapists', r['id'] as int); setState(() {}); })]))); }); }))]);
}

class BookingsPage extends StatefulWidget { final AppDb db; final int userId; const BookingsPage({super.key, required this.db, required this.userId}); @override State<BookingsPage> createState() => _BookingsPageState(); }
class _BookingsPageState extends State<BookingsPage> {
  DateTime day = DateTime.now();
  Future<List<Map<String, Object?>>> f() => widget.db.bookingsFor(day);

  String remaining(String start, String end, String status) {
    if (status == 'cancelled' || status == 'completed') return status == 'cancelled' ? 'ملغي' : 'مكتمل';
    final now = DateTime.now();
    final s = DateTime.tryParse(start);
    final e = DateTime.tryParse(end);
    if (s == null || e == null) return status;
    if (now.isBefore(s)) return 'متبقي حتى البداية: ${_durationText(s.difference(now))}';
    if (now.isBefore(e)) return 'الجلسة جارية — متبقي: ${_durationText(e.difference(now))}';
    return 'انتهت الجلسة';
  }

  String _durationText(Duration d) {
    final mins = d.inMinutes;
    if (mins < 1) return 'أقل من دقيقة';
    final h = mins ~/ 60, m = mins % 60;
    return h > 0 ? '$h س و $m د' : '$m د';
  }

  Future<void> addBooking() async {
    final customers = await widget.db.db.query('customers', orderBy: 'name');
    final services = await widget.db.db.query('services', where: 'active=1', orderBy: 'name_ar');
    final therapists = await widget.db.db.query('therapists', where: 'active=1', orderBy: 'name');
    if (!mounted) return;
    if (customers.isEmpty || services.isEmpty || therapists.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('يجب إضافة عميل وخدمة ومعالج نشط أولاً.')));
      return;
    }
    int customerId = customers.first['id'] as int;
    int serviceId = services.first['id'] as int;
    int therapistId = therapists.first['id'] as int;
    DateTime date = day;
    TimeOfDay time = const TimeOfDay(hour: 9, minute: 0);
    String notes = '';
    double total = ((services.first['price'] as num?) ?? 0).toDouble();
    int duration = ((services.first['duration'] as num?) ?? 0).toInt();
    final notesController = TextEditingController();
    String? error;

    await showDialog(context: context, builder: (dialogContext) => StatefulBuilder(builder: (ctx, setD) {
      final selectedService = services.firstWhere((x) => x['id'] == serviceId);
      total = ((selectedService['price'] as num?) ?? 0).toDouble();
      duration = ((selectedService['duration'] as num?) ?? 0).toInt();
      final startPreview = DateTime(date.year, date.month, date.day, time.hour, time.minute);
      final endPreview = startPreview.add(Duration(minutes: duration));
      return AlertDialog(
        title: const Text('حجز موعد جديد'),
        content: SizedBox(width: 520, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          DropdownButtonFormField<int>(value: customerId, decoration: const InputDecoration(labelText: 'العميل'), items: customers.map((x) => DropdownMenuItem(value: x['id'] as int, child: Text('${x['name']} — ${x['phone'] ?? ''}'))).toList(), onChanged: (v) { if (v != null) setD(() => customerId = v); }),
          DropdownButtonFormField<int>(value: serviceId, decoration: const InputDecoration(labelText: 'الخدمة'), items: services.map((x) => DropdownMenuItem(value: x['id'] as int, child: Text('${x['name_ar']} — ${x['duration']} دقيقة — ${x['price']}'))).toList(), onChanged: (v) { if (v != null) setD(() => serviceId = v); }),
          DropdownButtonFormField<int>(value: therapistId, decoration: const InputDecoration(labelText: 'المعالج'), items: therapists.map((x) => DropdownMenuItem(value: x['id'] as int, child: Text('${x['name']}'))).toList(), onChanged: (v) { if (v != null) setD(() => therapistId = v); }),
          const SizedBox(height: 8),
          Row(children: [Expanded(child: ListTile(contentPadding: EdgeInsets.zero, title: Text(DateFormat('yyyy-MM-dd').format(date)), subtitle: const Text('التاريخ'), trailing: const Icon(Icons.date_range), onTap: () async { final d = await showDatePicker(context: ctx, firstDate: DateTime.now().subtract(const Duration(days: 1)), lastDate: DateTime(2035), initialDate: date); if (d != null) setD(() => date = d); })), Expanded(child: ListTile(contentPadding: EdgeInsets.zero, title: Text(time.format(ctx)), subtitle: const Text('الوقت'), trailing: const Icon(Icons.access_time), onTap: () async { final t = await showTimePicker(context: ctx, initialTime: time); if (t != null) setD(() => time = t); }))]),
          Align(alignment: Alignment.centerRight, child: Text('النهاية المتوقعة: ${DateFormat('yyyy-MM-dd HH:mm').format(endPreview)}')),
          Align(alignment: Alignment.centerRight, child: Text('الإجمالي: ${total.toStringAsFixed(2)} | العربون 50%: ${(total * 0.5).toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold))),
          TextField(controller: notesController, maxLines: 3, decoration: const InputDecoration(labelText: 'ملاحظات الحجز')),
          if (error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(error!, style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold))),
        ]))),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')), FilledButton.icon(onPressed: () async {
          final start = DateTime(date.year, date.month, date.day, time.hour, time.minute);
          try {
            final userId = widget.userId;
            await widget.db.createBooking(customerId: customerId, serviceId: serviceId, therapistId: therapistId, start: start, notes: notesController.text.trim(), userId: userId);
            if (ctx.mounted) Navigator.pop(ctx);
            if (mounted) setState(() {});
          } catch (e) { setD(() => error = e.toString().replaceFirst('Exception: ', '')); }
        }, icon: const Icon(Icons.check), label: const Text('تأكيد الحجز'))],
      );
    }));
    notesController.dispose();
  }

  @override Widget build(BuildContext c) => Column(children: [
    Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 4), child: Row(children: [Expanded(child: ListTile(title: Text(DateFormat('yyyy-MM-dd').format(day)), subtitle: const Text('مواعيد اليوم'), leading: const Icon(Icons.calendar_month), onTap: () async { final d = await showDatePicker(context: context, firstDate: DateTime(2020), lastDate: DateTime(2035), initialDate: day); if (d != null) setState(() => day = d); })), FilledButton.icon(onPressed: addBooking, icon: const Icon(Icons.add_alarm), label: const Text('حجز جديد'))])),
    Expanded(child: FutureBuilder(future: f(), builder: (c, s) { final r = s.data ?? []; if (r.isEmpty) return const Center(child: Text('لا توجد حجوزات في هذا اليوم.')); return ListView(children: r.map((x) => Card(child: ListTile(leading: CircleAvatar(child: Text('${x['duration'] ?? ''}')), title: Text('${x['service_name'] ?? ''} — ${x['customer_name'] ?? ''}'), subtitle: Text('${x['start']}\nالمعالج: ${x['therapist_name'] ?? ''}\n${remaining('${x['start']}', '${x['end']}', '${x['status']}')}\nالحالة: ${x['status']} | الإجمالي: ${x['total']} | العربون: ${x['deposit']}'), isThreeLine: true))).toList()); }))
  ]);
}

class SalesPage extends StatefulWidget {
  final AppDb db; final int userId; const SalesPage({super.key, required this.db, required this.userId});
  @override State<SalesPage> createState() => _SalesPageState();
}
class _SalesPageState extends State<SalesPage> {
  Future<void> newInvoice() async {
    final bookings = await widget.db.db.rawQuery('''
      SELECT b.*, c.name customer_name, s.name_ar service_name
      FROM bookings b LEFT JOIN customers c ON c.id=b.customer_id LEFT JOIN services s ON s.id=b.service_id
      WHERE b.status NOT IN ('cancelled') AND NOT EXISTS (SELECT 1 FROM sales sa WHERE sa.booking_id=b.id)
      ORDER BY b.start DESC
    ''');
    if (!mounted) return;
    if (bookings.isEmpty) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('لا توجد حجوزات غير مفوترة.'))); return; }
    int bookingId = bookings.first['id'] as int;
    final currencies = (await widget.db.getSetting('currencies', 'JOD,USD,SAR,AED')).split(',').where((x) => x.isNotEmpty).toList();
    String currency = await widget.db.getSetting('default_currency', currencies.first);
    if (!currencies.contains(currency)) currency = currencies.first;
    await showDialog(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx,setD) => AlertDialog(
      title: const Text('إنشاء فاتورة من حجز'),
      content: SizedBox(width: 520, child: Column(mainAxisSize: MainAxisSize.min, children: [
        DropdownButtonFormField<int>(value: bookingId, decoration: const InputDecoration(labelText: 'الحجز'), items: bookings.map((b) => DropdownMenuItem(value: b['id'] as int, child: Text('#${b['id']} — ${b['customer_name']} — ${b['service_name']}'))).toList(), onChanged: (v){if(v!=null)setD(()=>bookingId=v);}),
        DropdownButtonFormField<String>(value: currency, decoration: const InputDecoration(labelText: 'العملة'), items: currencies.map((x)=>DropdownMenuItem(value:x,child:Text(x))).toList(), onChanged:(v){if(v!=null)setD(()=>currency=v);}),
      ])),
      actions: [TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')), FilledButton(onPressed:() async { try { await widget.db.createInvoice(bookingId: bookingId, userId: widget.userId, currency: currency); if(ctx.mounted)Navigator.pop(ctx); if(mounted)setState((){}); } catch(e){ ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.toString().replaceFirst('Exception: ','')))); } }, child:const Text('إنشاء'))],
    )));
  }
  Future<void> addPayment(Map<String,Object?> sale) async {
    final total=((sale['total'] as num?)??0).toDouble(); final paid=((sale['paid'] as num?)??0).toDouble(); final remaining=total-paid;
    if(remaining<=0){ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('الفاتورة مدفوعة بالكامل.')));return;}
    final amount=TextEditingController(text: remaining.toStringAsFixed(2)); final ref=TextEditingController(); final notes=TextEditingController();
    String method='نقدي'; final methods=['نقدي','بطاقة','CliQ','تحويل بنكي','أخرى'];
    await showDialog(context:context,builder:(ctx)=>StatefulBuilder(builder:(ctx,setD)=>AlertDialog(title:Text('دفعة للفواتير #${sale['id']}'),content:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
      Text('الإجمالي: ${total.toStringAsFixed(2)} ${sale['currency']}'), Text('المدفوع: ${paid.toStringAsFixed(2)} ${sale['currency']}'), Text('المتبقي: ${remaining.toStringAsFixed(2)} ${sale['currency']}'),
      TextField(controller:amount,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'قيمة الدفعة')),
      DropdownButtonFormField<String>(value:method,decoration:const InputDecoration(labelText:'طريقة الدفع'),items:methods.map((x)=>DropdownMenuItem(value:x,child:Text(x))).toList(),onChanged:(v){if(v!=null)setD(()=>method=v);}),
      TextField(controller:ref,decoration:const InputDecoration(labelText:'رقم المرجع (اختياري)')), TextField(controller:notes,decoration:const InputDecoration(labelText:'ملاحظات')),
    ])),actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),FilledButton(onPressed:()async{try{await widget.db.addPayment(saleId:sale['id'] as int,amount:double.tryParse(amount.text.trim())??0,currency:sale['currency'].toString(),method:method,reference:ref.text.trim(),notes:notes.text.trim(),userId:widget.userId);if(ctx.mounted)Navigator.pop(ctx);if(mounted)setState((){});}catch(e){ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.toString().replaceFirst('Exception: ',''))));}},child:const Text('حفظ الدفعة'))]})));
  }
  Future<void> details(Map<String,Object?> sale) async {
    final payments=await widget.db.paymentsForSale(sale['id'] as int);
    if(!mounted)return;
    final total=((sale['total'] as num?)??0).toDouble();
    final paid=((sale['paid'] as num?)??0).toDouble();
    await showDialog(context:context,builder:(ctx)=>AlertDialog(title:Text('الفاتورة #${sale['id']}'),content:SizedBox(width:560,height:380,child:ListView(children:[
      ListTile(title:Text('${sale['customer_name']??''} — ${sale['service_name']??''}'),subtitle:Text('الإجمالي: ${total.toStringAsFixed(2)} ${sale['currency']}\nالمدفوع: ${paid.toStringAsFixed(2)} ${sale['currency']}\nالمتبقي: ${(total-paid).toStringAsFixed(2)} ${sale['currency']}')),
      const Divider(),
      ...payments.map((p)=>ListTile(title:Text('${p['amount']} ${p['currency']} — ${p['method']}'),subtitle:Text('${p['created_at']}${p['reference'].toString().isNotEmpty?'\nمرجع: ${p['reference']}':''}')))
    ])),actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إغلاق'))]));
  }

  @override Widget build(BuildContext c)=>Column(children:[Padding(padding:const EdgeInsets.all(12),child:Row(children:[FilledButton.icon(onPressed:newInvoice,icon:const Icon(Icons.receipt_long),label:const Text('فاتورة جديدة')),const SizedBox(width:8),const Text('الدفعات محفوظة كسجل مستقل') ])),Expanded(child:FutureBuilder(future:widget.db.salesWithDetails(),builder:(c,s){final r=s.data??[];if(r.isEmpty)return const Center(child:Text('لا توجد فواتير.'));return ListView(children:r.map((x){final total=((x['total'] as num?)??0).toDouble();final paid=((x['paid_total'] as num?)??0).toDouble();final remaining=total-paid;return Card(child:ListTile(title:Text('فاتورة #${x['id']} — ${x['customer_name']??''}'),subtitle:Text('${x['service_name']??''}\nالإجمالي: ${total.toStringAsFixed(2)} ${x['currency']} | المدفوع: ${paid.toStringAsFixed(2)} | المتبقي: ${remaining.toStringAsFixed(2)}'),isThreeLine:true,trailing:Wrap(children:[IconButton(tooltip:'دفعة',icon:const Icon(Icons.payments),onPressed:()=>addPayment(x)),IconButton(tooltip:'التفاصيل',icon:const Icon(Icons.info_outline),onPressed:()=>details(x)),IconButton(tooltip:'طباعة',icon:const Icon(Icons.print),onPressed:()=>Invoice.printSale(x))]));}).toList());}))]);

}
class Invoice {
  static Future<void> printSale(Map<String,Object?> x) async {
    final doc=pw.Document(); final total=((x['total'] as num?)??0).toDouble(); final paid=((x['paid_total'] as num?)??(x['paid'] as num?)??0).toDouble();
    doc.addPage(pw.Page(build:(_)=>pw.Directionality(textDirection:pw.TextDirection.rtl,child:pw.Column(crossAxisAlignment:pw.CrossAxisAlignment.stretch,children:[pw.Text('مركز الحياة للمساج',style:pw.TextStyle(fontSize:24,fontWeight:pw.FontWeight.bold)),pw.SizedBox(height:18),pw.Text('فاتورة #${x['id']}'),pw.Text('العميل: ${x['customer_name']??x['customer_id']??''}'),pw.Text('الخدمة: ${x['service_name']??''}'),pw.SizedBox(height:12),pw.Text('الإجمالي: ${total.toStringAsFixed(2)} ${x['currency']}'),pw.Text('المدفوع: ${paid.toStringAsFixed(2)} ${x['currency']}'),pw.Text('المتبقي: ${(total-paid).toStringAsFixed(2)} ${x['currency']}'),pw.SizedBox(height:12),pw.Text('التاريخ: ${x['created_at']??''}'),pw.SizedBox(height:30),pw.Text('شكرًا لزيارتكم مركز الحياة للمساج.')] ))); await Printing.layoutPdf(onLayout:(_)=>doc.save());
  }
}
class ReportsPage extends StatefulWidget {
  final AppDb db;
  const ReportsPage({super.key, required this.db});
  @override State<ReportsPage> createState() => _ReportsPageState();
}
class _ReportsPageState extends State<ReportsPage> {
  DateTime from=DateTime(DateTime.now().year,DateTime.now().month,DateTime.now().day);
  DateTime to=DateTime(DateTime.now().year,DateTime.now().month,DateTime.now().day).add(const Duration(days:1));
  int tab=0;
  Future<void> pickRange() async {
    final d1=await showDatePicker(context:context,firstDate:DateTime(2020),lastDate:DateTime(2035),initialDate:from);
    if(d1==null||!mounted)return;
    final d2=await showDatePicker(context:context,firstDate:d1,lastDate:DateTime(2035),initialDate:to.subtract(const Duration(days:1)));
    if(d2==null)return;
    setState(()=>{from=DateTime(d1.year,d1.month,d1.day),to=DateTime(d2.year,d2.month,d2.day).add(const Duration(days:1))});
  }
  @override Widget build(BuildContext c)=>FutureBuilder<List<dynamic>>(future:Future.wait([widget.db.reportTotals(from,to),widget.db.reportByService(from,to),widget.db.reportByTherapist(from,to),widget.db.reportByPaymentMethod(from,to),widget.db.reportCustomersCount(from,to)]),builder:(c,s){
    if(!s.hasData)return const Center(child:CircularProgressIndicator());
    final totals=s.data![0] as Map<String,double>; final services=s.data![1] as List<Map<String,Object?>>; final therapists=s.data![2] as List<Map<String,Object?>>; final methods=s.data![3] as List<Map<String,Object?>>; final customers=s.data![4] as int;
    final currencies=totals.keys.where((k)=>k.endsWith('_total')).map((k)=>k.replaceFirst('_total','')).toSet().toList();
    return ListView(padding:const EdgeInsets.all(16),children:[
      Row(children:[Expanded(child:Text('من ${DateFormat('yyyy-MM-dd').format(from)} إلى ${DateFormat('yyyy-MM-dd').format(to.subtract(const Duration(days:1)))}',style:const TextStyle(fontWeight:FontWeight.bold))),FilledButton.icon(onPressed:pickRange,icon:const Icon(Icons.date_range),label:const Text('تغيير الفترة'))]),
      const SizedBox(height:12),
      Wrap(spacing:12,runSpacing:12,children:[StatCard(title:'العملاء',value:'$customers',icon:Icons.people),StatCard(title:'الفواتير',value:'${services.fold<int>(0,(a,x)=>a+((x['count'] as num?)??0).toInt())}',icon:Icons.receipt),StatCard(title:'الخدمات',value:'${services.length}',icon:Icons.spa)]),
      const SizedBox(height:16),
      ...currencies.map((cur){final total=totals['${cur}_total']??0;final paid=totals['${cur}_paid']??0;return Card(child:ListTile(title:Text('الإيرادات — $cur'),subtitle:Text('الإجمالي: ${total.toStringAsFixed(2)} $cur\nالمقبوض: ${paid.toStringAsFixed(2)} $cur\nالمتبقي: ${(total-paid).toStringAsFixed(2)} $cur'),isThreeLine:true));}),
      const SizedBox(height:8),
      SegmentedButton<int>(segments:const [ButtonSegment(value:0,label:Text('الخدمات')),ButtonSegment(value:1,label:Text('المعالجون')),ButtonSegment(value:2,label:Text('طرق الدفع'))],selected:{tab},onSelectionChanged:(v)=>setState(()=>tab=v.first)),
      const SizedBox(height:8),
      if(tab==0)...services.map((x)=>ListTile(title:Text(x['service_name'].toString()),subtitle:Text('عدد الفواتير: ${x['count']}'),trailing:Text('${((x['total'] as num?)??0).toStringAsFixed(2)}'))),
      if(tab==1)...therapists.map((x)=>ListTile(title:Text(x['therapist_name'].toString()),subtitle:Text('عدد الحجوزات: ${x['count']}'),trailing:Text('${((x['total'] as num?)??0).toStringAsFixed(2)}'))),
      if(tab==2)...methods.map((x)=>ListTile(title:Text('${x['method']} — ${x['currency']}'),subtitle:Text('عدد الدفعات: ${x['count']}'),trailing:Text('${((x['total'] as num?)??0).toStringAsFixed(2)}'))),
    ]);
  });
}
class UsersPage extends StatefulWidget {
  final AppDb db; final int currentUserId;
  const UsersPage({super.key, required this.db, required this.currentUserId});
  @override State<UsersPage> createState() => _UsersPageState();
}
class _UsersPageState extends State<UsersPage> {
  Future<void> edit([Map<String,Object?>? old]) async {
    final username = TextEditingController(text: old?['username']?.toString() ?? '');
    final password = TextEditingController();
    String role = old?['role']?.toString() ?? 'reception';
    bool active = (old?['active'] as num?)?.toInt() != 0;
    await showDialog(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx,setD)=>AlertDialog(title: Text(old==null?'إضافة مستخدم':'تعديل المستخدم'), content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [TextField(controller: username, decoration: const InputDecoration(labelText:'اسم المستخدم')), TextField(controller: password, obscureText:true, decoration: InputDecoration(labelText: old==null?'كلمة المرور':'كلمة مرور جديدة (اختياري)')), DropdownButtonFormField<String>(value: role, decoration: const InputDecoration(labelText:'الدور'), items: AppDb.roles.map((r)=>DropdownMenuItem(value:r,child:Text(_roleLabel(r)))).toList(), onChanged:(v){if(v!=null)setD(()=>role=v);}), SwitchListTile(value:active,onChanged:(v)=>setD(()=>active=v),title:const Text('الحساب نشط'))])), actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),FilledButton(onPressed:()async{try{await widget.db.saveUser(id:old == null ? null : old['id'] as int,username:username.text,password:password.text,role:role,active:active);if(ctx.mounted)Navigator.pop(ctx);if(mounted)setState((){});}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.toString().replaceFirst('Exception: ',''))));}},child:const Text('حفظ'))]));
  }
  String _roleLabel(String r)=>{'manager':'مدير','reception':'استقبال','therapist':'معالج','accountant':'محاسب'}[r]??r;
  @override Widget build(BuildContext c)=>Column(children:[Padding(padding:const EdgeInsets.all(12),child:Row(children:[FilledButton.icon(onPressed:()=>edit(),icon:const Icon(Icons.person_add),label:const Text('إضافة مستخدم')),const SizedBox(width:12),const Expanded(child:Text('الصلاحيات تعتمد على الدور المحدد لكل مستخدم.'))])),Expanded(child:FutureBuilder(future:widget.db.usersList(),builder:(c,s){final rows=s.data??[];return ListView(children:rows.map((r)=>Card(child:ListTile(leading:Icon(r['active']==1?Icons.person:Icons.person_off),title:Text('${r['username']} — ${_roleLabel(r['role'].toString())}'),subtitle:Text(r['active']==1?'نشط':'موقوف'),trailing:IconButton(icon:const Icon(Icons.edit),onPressed:()=>edit(r)))).toList());}))]);
}


class ExternalServicesPage extends StatefulWidget {
  final AppDb db;
  const ExternalServicesPage({super.key, required this.db});
  @override State<ExternalServicesPage> createState() => _ExternalServicesPageState();
}
class _ExternalServicesPageState extends State<ExternalServicesPage> {
  bool online = false;
  bool loading = false;
  Map<String, dynamic>? weather;
  String weatherError = '';
  Future<void> checkOnline() async {
    setState(() => loading = true);
    try {
      final r = await http.get(Uri.parse('https://www.google.com/generate_204')).timeout(const Duration(seconds: 5));
      online = r.statusCode >= 200 && r.statusCode < 400;
    } catch (_) { online = false; }
    if (mounted) setState(() => loading = false);
  }
  Future<void> loadWeather() async {
    setState(() { loading = true; weatherError = ''; });
    try {
      final lat = double.parse(await widget.db.getSetting('weather_lat', '31.9539'));
      final lon = double.parse(await widget.db.getSetting('weather_lon', '35.9106'));
      final uri = Uri.parse('https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon&current=temperature_2m,relative_humidity_2m,weather_code,wind_speed_10m&timezone=auto');
      final r = await http.get(uri).timeout(const Duration(seconds: 8));
      if (r.statusCode != 200) throw Exception('تعذر جلب الطقس.');
      weather = jsonDecode(r.body) as Map<String, dynamic>;
    } catch (e) { weatherError = e.toString().replaceFirst('Exception: ', ''); }
    if (mounted) setState(() => loading = false);
  }
  Future<void> openUrl(String value) async {
    final u = Uri.tryParse(value.trim());
    if (u == null || !await canLaunchUrl(u)) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('الرابط غير صالح أو غير متاح.'))); return; }
    await launchUrl(u, mode: LaunchMode.externalApplication);
  }
  Future<void> whatsapp() async {
    final number = (await widget.db.getSetting('whatsapp_number', '')).replaceAll(RegExp(r'[^0-9]'), '');
    if (number.isEmpty) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('أضف رقم WhatsApp أولاً من الإعدادات.'))); return; }
    await openUrl('https://wa.me/$number');
  }
  String weatherText(int code) {
    if (code == 0) return 'سماء صافية';
    if ([1,2,3].contains(code)) return 'غائم جزئيًا / غائم';
    if ([45,48].contains(code)) return 'ضباب';
    if ([51,53,55,56,57].contains(code)) return 'رذاذ';
    if ([61,63,65,66,67].contains(code)) return 'أمطار';
    if ([71,73,75,77].contains(code)) return 'ثلوج';
    if ([80,81,82].contains(code)) return 'زخات مطر';
    if ([95,96,99].contains(code)) return 'عواصف رعدية';
    return 'حالة جوية متغيرة';
  }
  Future<void> shareBackup() async {
    final dir = await getApplicationDocumentsDirectory();
    final src = File(p.join(dir.path, 'life_massage.db'));
    if (!await src.exists()) return;
    await Share.shareXFiles([XFile(src.path)], text: 'نسخة احتياطية لمركز الحياة للمساج');
  }
  @override Widget build(BuildContext c) {
    final city = widget.db.getSetting('weather_city', 'Amman');
    return FutureBuilder<String>(future: city, builder: (ctx, snap) => ListView(padding: const EdgeInsets.all(16), children: [
      Card(child: ListTile(leading: Icon(online ? Icons.cloud_done : Icons.cloud_off), title: Text(loading ? 'جاري التحقق...' : (online ? 'متصل بالإنترنت' : 'غير متصل بالإنترنت')), subtitle: const Text('التطبيق يعمل محليًا حتى عند انقطاع الإنترنت.'), trailing: IconButton(onPressed: loading ? null : checkOnline, icon: const Icon(Icons.refresh)))),
      Card(child: ListTile(leading: const Icon(Icons.chat), title: const Text('WhatsApp'), subtitle: const Text('فتح محادثة المركز باستخدام الرقم المحفوظ.'), trailing: FilledButton(onPressed: whatsapp, child: const Text('فتح')))),
      Card(child: ListTile(leading: const Icon(Icons.share), title: const Text('مشاركة النسخة الاحتياطية'), subtitle: const Text('إرسال ملف قاعدة البيانات عبر تطبيقات المشاركة.'), trailing: FilledButton(onPressed: shareBackup, child: const Text('مشاركة')))),
      Card(child: ListTile(leading: const Icon(Icons.cloud), title: const Text('المزامنة السحابية'), subtitle: const Text('النسخة الحالية تعتمد على قاعدة بيانات محلية. لم يتم ربط خادم سحابي بعد.'), trailing: const Chip(label: Text('محلي')))),
      Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [const Text('الطقس', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)), const SizedBox(height: 8), Text('المدينة: ${snap.data ?? 'Amman'}'), const SizedBox(height: 8), if (weather != null) Builder(builder: (_) { final cur = weather!['current'] as Map<String, dynamic>; return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('${(cur['temperature_2m'] as num?)?.toStringAsFixed(1) ?? '-'} °C', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)), Text(weatherText((cur['weather_code'] as num?)?.toInt() ?? -1)), Text('الرطوبة: ${cur['relative_humidity_2m'] ?? '-'}% | الرياح: ${cur['wind_speed_10m'] ?? '-'} km/h')]); }), if (weatherError.isNotEmpty) Text(weatherError), const SizedBox(height: 8), FilledButton.icon(onPressed: loading ? null : loadWeather, icon: const Icon(Icons.wb_sunny), label: const Text('تحديث الطقس'))]))),
    ]));
  }
}

class SettingsPage extends StatefulWidget { final AppDb db; final int userId; const SettingsPage({super.key, required this.db, required this.userId}); @override State<SettingsPage> createState() => _SettingsPageState(); }
class _SettingsPageState extends State<SettingsPage> {
  Future<void> backup(BuildContext context) async { try { final out = await widget.db.createBackup(); await SharePlus.instance.share(ShareParams(files: [XFile(out.path)], text: 'نسخة احتياطية لمركز الحياة للمساج')); if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم إنشاء النسخة والتحقق من سلامتها.'))); } catch (e) { if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', '')))); } }
  Future<void> restoreBackup(BuildContext context) async {
    final files = await widget.db.listBackups();
    if (!context.mounted) return;
    if (files.isEmpty) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('لا توجد نسخ احتياطية داخل التطبيق.'))); return; }
    await showDialog(context: context, builder: (ctx) => AlertDialog(title: const Text('استعادة نسخة احتياطية'), content: SizedBox(width: 520, height: 360, child: ListView(children: files.map((f) => FutureBuilder<bool>(future: widget.db.verifyBackup(f), builder: (c,s) => ListTile(leading: Icon(s.data == true ? Icons.verified : Icons.error), title: Text(p.basename(f.path)), subtitle: Text(s.data == true ? 'النسخة سليمة' : 'التحقق فشل'), trailing: FilledButton(onPressed: s.data == true ? () async { final ok = await showDialog<bool>(context: ctx, builder: (c2) => AlertDialog(title: const Text('تأكيد الاستعادة'), content: const Text('سيتم استبدال قاعدة البيانات الحالية بهذه النسخة. هل تريد المتابعة؟'), actions: [TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('إلغاء')), FilledButton(onPressed: () => Navigator.pop(c2, true), child: const Text('استعادة'))])); if (ok == true) { try { await widget.db.restoreBackup(f); if (ctx.mounted) Navigator.pop(ctx); if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تمت الاستعادة بنجاح. يُفضّل إعادة تشغيل التطبيق.'))); } catch (e) { if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', '')))); } } } : null, child: const Text('استعادة')))).toList())), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إغلاق'))]);
  }
  Future<void> scheduleSettings() async {
    final start = TextEditingController(text: await widget.db.getSetting('work_start', '09:00'));
    final end = TextEditingController(text: await widget.db.getSetting('work_end', '22:00'));
    String days = await widget.db.getSetting('work_days', '1,2,3,4,5,6,7');
    final selected = days.split(',').where((x) => x.isNotEmpty).map(int.parse).toSet();
    final labels = const {1:'الإثنين',2:'الثلاثاء',3:'الأربعاء',4:'الخميس',5:'الجمعة',6:'السبت',7:'الأحد'};
    if (!mounted) return;
    await showDialog(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(title: const Text('ساعات وأيام العمل'), content: SingleChildScrollView(child: Column(children: [TextField(controller: start, decoration: const InputDecoration(labelText: 'بداية العمل HH:mm')), TextField(controller: end, decoration: const InputDecoration(labelText: 'نهاية العمل HH:mm')), const SizedBox(height: 12), ...labels.entries.map((e) => CheckboxListTile(value: selected.contains(e.key), title: Text(e.value), onChanged: (v) => setD(() { if (v == true) selected.add(e.key); else selected.remove(e.key); })))])), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')), FilledButton(onPressed: () async { await widget.db.setSetting('work_start', start.text.trim()); await widget.db.setSetting('work_end', end.text.trim()); await widget.db.setSetting('work_days', (selected.toList()..sort()).join(',')); if (ctx.mounted) Navigator.pop(ctx); setState(() {}); }, child: const Text('حفظ'))]));
  }
  Future<void> holidays() async { final rows = await widget.db.all('holidays'); if (!mounted) return; await showDialog(context: context, builder: (ctx) => AlertDialog(title: const Text('العطل والاستثناءات'), content: SizedBox(width: 520, height: 360, child: Column(children: [Align(alignment: Alignment.centerRight, child: FilledButton.icon(onPressed: () async { final d = await showDatePicker(context: ctx, firstDate: DateTime.now().subtract(const Duration(days: 365)), lastDate: DateTime(2035), initialDate: DateTime.now()); if (d == null) return; final reason = TextEditingController(); final ok = await showDialog<bool>(context: ctx, builder: (c2) => AlertDialog(title: const Text('إضافة عطلة'), content: TextField(controller: reason, decoration: const InputDecoration(labelText: 'السبب')), actions: [TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('إلغاء')), FilledButton(onPressed: () => Navigator.pop(c2, true), child: const Text('حفظ'))])); if (ok == true) { try { await widget.db.insert('holidays', {'date': DateFormat('yyyy-MM-dd').format(d), 'reason': reason.text.trim()}); } catch (_) {} if (ctx.mounted) Navigator.pop(ctx); if (mounted) holidays(); } }, icon: const Icon(Icons.event_busy), label: const Text('إضافة عطلة'))), const SizedBox(height: 8), Expanded(child: ListView(children: rows.map((r) => ListTile(title: Text('${r['date']}'), subtitle: Text('${r['reason'] ?? ''}'), trailing: IconButton(icon: const Icon(Icons.delete), onPressed: () async { await widget.db.delete('holidays', r['id'] as int); if (ctx.mounted) Navigator.pop(ctx); if (mounted) holidays(); })).toList()))])), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إغلاق'))])); }
  Future<void> currencySettings() async {
    final currencies = (await widget.db.getSetting('currencies', 'JOD,USD,SAR,AED')).split(',').where((x)=>x.isNotEmpty).toList();
    String current = await widget.db.getSetting('default_currency', currencies.first);
    if (!currencies.contains(current)) current = currencies.first;
    if (!mounted) return;
    await showDialog(context: context, builder:(ctx)=>AlertDialog(title:const Text('العملة الافتراضية'),content:DropdownButtonFormField<String>(value:current,items:currencies.map((x)=>DropdownMenuItem(value:x,child:Text(x))).toList(),onChanged:(v){if(v!=null)current=v;}),actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),FilledButton(onPressed:()async{await widget.db.setSetting('default_currency',current);if(ctx.mounted)Navigator.pop(ctx);if(mounted)setState((){});},child:const Text('حفظ'))]));
  }
  Future<void> externalSettings() async {
    final wa = TextEditingController(text: await widget.db.getSetting('whatsapp_number', ''));
    final fb = TextEditingController(text: await widget.db.getSetting('facebook_url', ''));
    final ig = TextEditingController(text: await widget.db.getSetting('instagram_url', ''));
    final maps = TextEditingController(text: await widget.db.getSetting('google_maps_url', ''));
    final city = TextEditingController(text: await widget.db.getSetting('weather_city', 'Amman'));
    final lat = TextEditingController(text: await widget.db.getSetting('weather_lat', '31.9539'));
    final lon = TextEditingController(text: await widget.db.getSetting('weather_lon', '35.9106'));
    await showDialog(context: context, builder: (ctx) => AlertDialog(title: const Text('الخدمات الخارجية'), content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
      TextField(controller: wa, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'رقم WhatsApp بصيغة دولية')),
      TextField(controller: fb, decoration: const InputDecoration(labelText: 'رابط Facebook')),
      TextField(controller: ig, decoration: const InputDecoration(labelText: 'رابط Instagram')),
      TextField(controller: maps, decoration: const InputDecoration(labelText: 'رابط Google Maps')),
      const Divider(),
      TextField(controller: city, decoration: const InputDecoration(labelText: 'مدينة الطقس')),
      TextField(controller: lat, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'خط العرض')),
      TextField(controller: lon, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'خط الطول')),
    ])), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')), FilledButton(onPressed: () async { await widget.db.setSetting('whatsapp_number', wa.text.trim()); await widget.db.setSetting('facebook_url', fb.text.trim()); await widget.db.setSetting('instagram_url', ig.text.trim()); await widget.db.setSetting('google_maps_url', maps.text.trim()); await widget.db.setSetting('weather_city', city.text.trim().isEmpty ? 'Amman' : city.text.trim()); await widget.db.setSetting('weather_lat', lat.text.trim()); await widget.db.setSetting('weather_lon', lon.text.trim()); if (ctx.mounted) Navigator.pop(ctx); if (mounted) setState(() {}); }, child: const Text('حفظ'))]));
  }

  Future<void> changePassword() async {
    final old = TextEditingController(), next = TextEditingController(), confirm = TextEditingController();
    await showDialog(context: context, builder: (ctx) => AlertDialog(title: const Text('تغيير كلمة المرور'), content: Column(mainAxisSize: MainAxisSize.min, children: [TextField(controller: old, obscureText: true, decoration: const InputDecoration(labelText: 'كلمة المرور الحالية')), TextField(controller: next, obscureText: true, decoration: const InputDecoration(labelText: 'كلمة المرور الجديدة')), TextField(controller: confirm, obscureText: true, decoration: const InputDecoration(labelText: 'تأكيد كلمة المرور'))]), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')), FilledButton(onPressed: () async { if (next.text != confirm.text) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تأكيد كلمة المرور غير مطابق.'))); return; } try { await widget.db.changeOwnPassword(widget.userId, old.text, next.text); if (ctx.mounted) Navigator.pop(ctx); if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم تغيير كلمة المرور.'))); } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', '')))); } }, child: const Text('حفظ'))]));
  }

  @override Widget build(BuildContext c) => ListView(padding: const EdgeInsets.all(16), children: [Card(child: ListTile(title: const Text('العملة والفوترة'), subtitle: const Text('العملات المتاحة: JOD / USD / SAR / AED'), trailing: FilledButton(onPressed: currencySettings, child: const Text('إعداد')))), Card(child: ListTile(title: const Text('إعدادات المواعيد'), subtitle: const Text('ساعات وأيام العمل ومنع الحجز خارجها'), trailing: FilledButton(onPressed: scheduleSettings, child: const Text('إعداد')))), Card(child: ListTile(title: const Text('العطل'), subtitle: const Text('منع الحجز في أيام العطل المسجلة'), trailing: FilledButton(onPressed: holidays, child: const Text('إدارة')))), Card(child: ListTile(title: const Text('الخدمات الخارجية'), subtitle: const Text('WhatsApp وFacebook وInstagram وGoogle Maps والطقس'), trailing: FilledButton(onPressed: externalSettings, child: const Text('إعداد')))), Card(child: ListTile(title: const Text('النسخ الاحتياطي والاستعادة'), subtitle: const Text('نسخ محلية مع فحص SHA-256 ومشاركة النسخة واستعادتها'), trailing: Wrap(spacing: 8, children: [FilledButton(onPressed: () => backup(c), child: const Text('نسخ ومشاركة')), OutlinedButton(onPressed: () => restoreBackup(c), child: const Text('استعادة'))]))), Card(child: ListTile(leading: const Icon(Icons.security), title: const Text('الأمان'), subtitle: const Text('كلمات المرور مجزأة، مع منع مؤقت بعد 5 محاولات دخول فاشلة وتغيير كلمة المرور من الإعدادات.')))]);
}

