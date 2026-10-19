import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:wspolne/wspolne.dart' show emailKey;

import '../config.dart';
import '../domain/models.dart';

enum AddMemberResult { added, alreadyMember, notFound }

class JoinException implements Exception {
  const JoinException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Dane sklepu w Firestore (projekt wspólny z Zakupami i Powrotem).
///
/// ```
/// groups/{gid}                     name, ownerId, members[], memberEmails{}, trustedSigners[]
/// groups/{gid}/apps/{appId}        StoreApp (+ latest - zapisuje CI)
/// groups/{gid}/installs/{uid_pkg}  kto ma którą wersję
/// invites/{kod}                    groupId, groupName, createdBy, expiresAt
/// ```
/// Reguły: firebase/firestore.rules
class StoreRepository {
  StoreRepository(this.uid, this.email, {FirebaseFirestore? db}) : db = db ?? FirebaseFirestore.instance;

  final String uid;
  final String email;
  final FirebaseFirestore db;

  CollectionReference<Map<String, dynamic>> get _groups => db.collection('groups');
  CollectionReference<Map<String, dynamic>> _apps(String gid) => _groups.doc(gid).collection('apps');

  // ------------------------------------------------------------------ grupy

  Stream<List<StoreGroup>> watchMyGroups() => _groups
      .where('members', arrayContains: uid)
      .snapshots()
      .map((s) => s.docs.map(StoreGroup.fromDoc).toList()..sort((a, b) => a.name.compareTo(b.name)));

  Stream<StoreGroup?> watchGroup(String gid) =>
      _groups.doc(gid).snapshots().map((d) => d.exists ? StoreGroup.fromDoc(d) : null);

  Future<String> createGroup(String name) async {
    final ref = await _groups.add({
      'name': name.trim(),
      'ownerId': uid,
      'members': [uid],
      'memberEmails': {uid: emailKey(email)},
      'trustedSigners': <String>[],
      // Nowe aplikacje dopisują się same przy pierwszym wydaniu (tools/ci-publish).
      'autoAdd': true,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    return ref.id;
  }

  Future<void> renameGroup(String gid, String name) =>
      _groups.doc(gid).update({'name': name.trim(), 'updatedAt': FieldValue.serverTimestamp()});

  Future<void> deleteGroup(String gid) async {
    final apps = await _apps(gid).get();
    final installs = await _groups.doc(gid).collection('installs').get();
    final batch = db.batch();
    for (final d in [...apps.docs, ...installs.docs]) {
      batch.delete(d.reference);
    }
    batch.delete(_groups.doc(gid));
    await batch.commit();
  }

  /// Dopisanie osoby po e-mailu (musi mieć konto - wpis w książce adresowej `emails`).
  Future<AddMemberResult> addMemberByEmail(StoreGroup group, String memberEmail) async {
    final key = emailKey(memberEmail);
    final entry = await db.collection('emails').doc(key).get();
    final memberUid = entry.data()?['uid'] as String?;
    if (!entry.exists || memberUid == null) return AddMemberResult.notFound;
    if (group.members.contains(memberUid)) return AddMemberResult.alreadyMember;
    await _groups.doc(group.id).update({
      'members': FieldValue.arrayUnion([memberUid]),
      FieldPath(['memberEmails', memberUid]): key,
      'updatedAt': FieldValue.serverTimestamp(),
    });
    return AddMemberResult.added;
  }

  Future<void> removeMember(String gid, String memberUid) => _groups.doc(gid).update({
        'members': FieldValue.arrayRemove([memberUid]),
        FieldPath(['memberEmails', memberUid]): FieldValue.delete(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

  Future<void> addTrustedSigner(String gid, String sha256) => _groups.doc(gid).update({
        'trustedSigners': FieldValue.arrayUnion([sha256]),
        'updatedAt': FieldValue.serverTimestamp(),
      });

  Future<void> removeTrustedSigner(String gid, String sha256) => _groups.doc(gid).update({
        'trustedSigners': FieldValue.arrayRemove([sha256]),
        'updatedAt': FieldValue.serverTimestamp(),
      });

  // ------------------------------------------------------------------ aplikacje

  Stream<List<StoreApp>> watchApps(String gid) => _apps(gid).snapshots().map((s) =>
      s.docs.map((d) => StoreApp.fromDoc(gid, d)).toList()
        ..sort((a, b) {
          final o = a.order.compareTo(b.order);
          return o != 0 ? o : a.name.toLowerCase().compareTo(b.name.toLowerCase());
        }));

  Future<void> saveApp(String gid, StoreApp app) {
    final data = {...app.toEditableJson(), 'updatedAt': FieldValue.serverTimestamp()};
    if (app.id.isEmpty) return _apps(gid).add({...data, 'createdAt': FieldValue.serverTimestamp()});
    return _apps(gid).doc(app.id).set(data, SetOptions(merge: true));
  }

  Future<void> deleteApp(String gid, String appId) => _apps(gid).doc(appId).delete();

  // ------------------------------------------------------------------ zaproszenia

  static const _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // bez 0/O, 1/I

  Future<Invite> createInvite(StoreGroup group) async {
    final rnd = Random.secure();
    final code = List.generate(8, (_) => _alphabet[rnd.nextInt(_alphabet.length)]).join();
    final expires = DateTime.now().add(StoreConfig.inviteValidity);
    await db.collection('invites').doc(code).set({
      'groupId': group.id,
      'groupName': group.name,
      'createdBy': uid,
      'expiresAt': Timestamp.fromDate(expires),
      'createdAt': FieldValue.serverTimestamp(),
    });
    return Invite(code: code, groupId: group.id, groupName: group.name, createdBy: uid, expiresAt: expires);
  }

  Stream<List<Invite>> watchMyInvites(String gid) => db
      .collection('invites')
      .where('createdBy', isEqualTo: uid)
      .snapshots()
      .map((s) => s.docs.map(Invite.fromDoc).where((i) => i.groupId == gid).toList()
        ..sort((a, b) => b.expiresAt.compareTo(a.expiresAt)));

  Future<void> deleteInvite(String code) => db.collection('invites').doc(code).delete();

  /// Kod z linku albo wpisany ręcznie: wielkie litery, bez spacji i myślników.
  static String normalizeCode(String raw) => raw.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  /// Dołączenie do grupy kodem. Zwraca nazwę grupy.
  Future<String> joinWithCode(String rawCode) async {
    final code = normalizeCode(rawCode);
    if (code.length < 6) throw const JoinException('Za krótki kod zaproszenia.');
    final snap = await db.collection('invites').doc(code).get();
    if (!snap.exists) throw const JoinException('Nie ma takiego zaproszenia. Sprawdź kod.');
    final invite = Invite.fromDoc(snap);
    if (!invite.isValid) throw const JoinException('Zaproszenie wygasło. Poproś o nowe.');
    try {
      await _groups.doc(invite.groupId).update({
        'members': FieldValue.arrayUnion([uid]),
        FieldPath(['memberEmails', uid]): emailKey(email),
        'lastInvite': code,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } on FirebaseException catch (e) {
      if (e.code != 'permission-denied') rethrow;
      // Reguły odrzucają też ponowne dołączenie - sprawdź, czy już jesteśmy w grupie.
      try {
        final g = await _groups.doc(invite.groupId).get();
        if (g.exists && StoreGroup.fromDoc(g).members.contains(uid)) return invite.groupName;
      } catch (_) {}
      throw const JoinException('Nie udało się dołączyć - zaproszenie jest nieważne.');
    }
    return invite.groupName;
  }

  // ------------------------------------------------------------------ kto ma którą wersję

  Future<void> reportInstall(String gid, InstalledApp app) =>
      _groups.doc(gid).collection('installs').doc('${uid}_${app.packageName}').set({
        'uid': uid,
        'email': emailKey(email),
        'packageName': app.packageName,
        'versionName': app.versionName,
        'versionCode': app.versionCode,
        'updatedAt': FieldValue.serverTimestamp(),
      });

  Future<void> clearInstall(String gid, String packageName) =>
      _groups.doc(gid).collection('installs').doc('${uid}_$packageName').delete();

  Stream<List<InstallReport>> watchInstalls(String gid) => _groups
      .doc(gid)
      .collection('installs')
      .snapshots()
      .map((s) => s.docs.map(InstallReport.fromDoc).toList());
}
