// Tests ../firestore.rules against the Firestore emulator.
// Each "app:" test replays a Firestore operation the Flutter app performs,
// so a rules change that would break the app fails here first.
//
//   npm install && npm test

import { readFileSync } from 'node:fs';
import { after, before, beforeEach, describe, test } from 'node:test';

import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from '@firebase/rules-unit-testing';
import {
  Timestamp,
  addDoc,
  collection,
  deleteDoc,
  deleteField,
  doc,
  getDoc,
  getDocs,
  limit,
  orderBy,
  query,
  runTransaction,
  serverTimestamp,
  setDoc,
  updateDoc,
  where,
  writeBatch,
} from 'firebase/firestore';

const HOUR = 60 * 60 * 1000;
const inHours = (h) => Timestamp.fromMillis(Date.now() + h * HOUR);

let env;
let db;

before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'demo-multicam',
    firestore: { rules: readFileSync(new URL('../firestore.rules', import.meta.url), 'utf8') },
  });
});

after(async () => env?.cleanup());

beforeEach(async () => {
  await env.clearFirestore();
  // The app has no auth, so every client is unauthenticated.
  db = env.unauthenticatedContext().firestore();
});

/** Seeds data bypassing the rules. */
const seed = (fn) => env.withSecurityRulesDisabled((ctx) => fn(ctx.firestore()));

/** Mirrors FirebaseSessionDataSource.createSession's transaction. */
function createSession(code, sessionId = `session${code}`) {
  const codeRef = doc(db, 'session_codes', code);
  const sessionRef = doc(db, 'sessions', sessionId);
  return runTransaction(db, async (tx) => {
    await tx.get(codeRef);
    tx.set(sessionRef, {
      adminId: 'admin-1',
      status: 'waiting',
      code,
      createdAt: serverTimestamp(),
      expiresAt: inHours(24 * 7),
    });
    tx.set(codeRef, {
      sessionId,
      createdAt: serverTimestamp(),
      expiresAt: inHours(24),
    });
  });
}

/** Mirrors FirebaseSessionDataSource.endSession's transaction. */
function endSession(sessionId) {
  const sessionRef = doc(db, 'sessions', sessionId);
  return runTransaction(db, async (tx) => {
    const session = await tx.get(sessionRef);
    const codeRef = doc(db, 'session_codes', session.data().code);
    const codeDoc = await tx.get(codeRef);
    if (codeDoc.data()?.sessionId === sessionId) tx.delete(codeRef);
    tx.update(sessionRef, { status: 'ended' });
  });
}

const sessionDoc = (id = 'session123456') => doc(db, 'sessions', id);
const sub = (path, id = 'session123456') => collection(db, 'sessions', id, ...path);

describe('session lifecycle', () => {
  test('app: admin creates a session under a free code', async () => {
    await assertSucceeds(createSession('123456'));
  });

  test('app: camera resolves a code and reads the session', async () => {
    await createSession('123456');
    await assertSucceeds(getDoc(doc(db, 'session_codes', '123456')));
    await assertSucceeds(getDoc(sessionDoc()));
  });

  test("a live session's code cannot be overwritten", async () => {
    await createSession('123456');
    await assertFails(createSession('123456', 'attackerSession'));
    await assertFails(
      setDoc(doc(db, 'session_codes', '123456'), {
        sessionId: 'attackerSession',
        createdAt: serverTimestamp(),
      }),
    );
  });

  test('app: an expired code can be claimed by a new session', async () => {
    await seed((sdb) =>
      setDoc(doc(sdb, 'session_codes', '123456'), {
        sessionId: 'old',
        createdAt: Timestamp.fromMillis(Date.now() - 48 * HOUR),
        expiresAt: Timestamp.fromMillis(Date.now() - HOUR),
      }),
    );
    await assertSucceeds(createSession('123456', 'newSession'));
  });

  test('a legacy code without expiresAt expires 24 h after createdAt', async () => {
    await seed((sdb) =>
      setDoc(doc(sdb, 'session_codes', '111111'), {
        sessionId: 'old',
        createdAt: Timestamp.fromMillis(Date.now() - 25 * HOUR),
      }),
    );
    await seed((sdb) =>
      setDoc(doc(sdb, 'session_codes', '222222'), {
        sessionId: 'recent',
        createdAt: Timestamp.fromMillis(Date.now() - HOUR),
      }),
    );
    await assertSucceeds(createSession('111111', 'a'));
    await assertFails(createSession('222222', 'b'));
  });

  test('codes and sessions cannot be listed', async () => {
    await createSession('123456');
    await assertFails(getDocs(collection(db, 'session_codes')));
    await assertFails(getDocs(collection(db, 'sessions')));
  });

  test('malformed codes and sessions are rejected', async () => {
    await assertFails(
      setDoc(doc(db, 'session_codes', 'abc'), { sessionId: 's', createdAt: serverTimestamp() }),
    );
    await assertFails(
      setDoc(doc(db, 'session_codes', '123456'), {
        sessionId: 's',
        createdAt: serverTimestamp(),
        extra: 'x',
      }),
    );
    await assertFails(
      setDoc(sessionDoc(), {
        adminId: 'a',
        status: 'live',
        code: '123456',
        createdAt: serverTimestamp(),
      }),
    );
  });

  test('app: admin ends a session, freeing its code', async () => {
    await createSession('123456');
    await assertSucceeds(endSession('session123456'));
    const code = await getDoc(doc(db, 'session_codes', '123456'));
    if (code.exists()) throw new Error('code should be freed');
  });

  test("a live session's code cannot be deleted", async () => {
    await createSession('123456');
    await assertFails(deleteDoc(doc(db, 'session_codes', '123456')));
  });

  test('only the status of a session can change, and ended is final', async () => {
    await createSession('123456');
    await assertFails(updateDoc(sessionDoc(), { adminId: 'attacker' }));
    await assertFails(updateDoc(sessionDoc(), { status: 'hacked' }));
    await endSession('session123456');
    await assertFails(updateDoc(sessionDoc(), { status: 'waiting' }));
  });

  test('a live session cannot be deleted; an ended one can', async () => {
    await createSession('123456');
    await assertFails(deleteDoc(sessionDoc()));
    await endSession('session123456');
    await assertSucceeds(deleteDoc(sessionDoc()));
  });
});

describe('data under a session', () => {
  beforeEach(() => createSession('123456'));

  test('app: camera registers and exchanges signaling', async () => {
    const peer = doc(db, 'sessions', 'session123456', 'peers', 'peer-1');
    const exp = { expiresAt: inHours(24 * 7) };
    await assertSucceeds(
      setDoc(peer, { deviceName: 'Pixel', joinedAt: serverTimestamp(), capabilities: [], ...exp }, { merge: true }),
    );
    await assertSucceeds(setDoc(peer, { offer: { sdp: 'v=0', type: 'offer' }, ...exp }, { merge: true }));
    await assertSucceeds(setDoc(peer, { answer: { sdp: 'v=0', type: 'answer' }, ...exp }, { merge: true }));
    await assertSucceeds(getDocs(sub(['peers']))); // watchPeers
    await assertSucceeds(getDoc(peer)); // watchPeerDocument

    for (const side of ['admin_candidates', 'camera_candidates']) {
      await assertSucceeds(
        addDoc(sub(['peers', 'peer-1', side]), {
          candidate: 'candidate:1 1 udp 1 192.168.1.2 5000 typ host',
          sdpMid: '0',
          sdpMLineIndex: 0,
          ...exp,
        }),
      );
      await assertSucceeds(getDocs(sub(['peers', 'peer-1', side])));
    }

    // clearPeerSignaling
    await assertSucceeds(updateDoc(peer, { offer: deleteField(), answer: deleteField() }));
    const cands = await getDocs(query(sub(['peers', 'peer-1', 'admin_candidates']), limit(500)));
    const batch = writeBatch(db);
    cands.docs.forEach((d) => batch.delete(d.ref));
    await assertSucceeds(batch.commit());
  });

  test('app: timed commands are published and watched', async () => {
    await assertSucceeds(
      setDoc(doc(sub(['commands'])), {
        type: 'startRecording',
        issuedAt: serverTimestamp(),
        bufferMs: 1000,
        executeAtMs: Date.now() + 1000,
        targetPeerId: null,
        payload: null,
        expiresAt: inHours(24 * 7),
      }),
    );
    await assertSucceeds(
      getDocs(query(sub(['commands']), where('issuedAt', '>=', Timestamp.fromMillis(Date.now() - 10_000)))),
    );
  });

  test('app: recordings and the timeline are written and read', async () => {
    await assertSucceeds(
      addDoc(sub(['recordings']), {
        peerId: 'peer-1',
        filename: 'rec.mp4',
        localIp: '192.168.1.2',
        port: 8080,
        sizeBytes: 1,
        recordedAt: serverTimestamp(),
        expiresAt: inHours(24 * 7),
      }),
    );
    await assertSucceeds(getDocs(sub(['recordings'])));
    await assertSucceeds(
      addDoc(sub(['timeline']), { timestamp: new Date().toISOString(), peerId: 'peer-1', expiresAt: inHours(24 * 7) }),
    );
    await assertSucceeds(getDocs(query(sub(['timeline']), orderBy('timestamp'))));
    // initTimeline clears the previous take
    const tl = await getDocs(sub(['timeline']));
    const batch = writeBatch(db);
    tl.docs.forEach((d) => batch.delete(d.ref));
    await assertSucceeds(batch.commit());
  });

  test('nothing can be written into a session that does not exist', async () => {
    await assertFails(addDoc(sub(['commands'], 'missingSession'), { type: 'startRecording' }));
    await assertFails(getDocs(sub(['peers'], 'missingSession')));
  });

  test('app: after ending, no new data but the cleanup can delete everything', async () => {
    const rec = await addDoc(sub(['recordings']), { peerId: 'p', expiresAt: inHours(1) });
    await endSession('session123456');
    await assertFails(addDoc(sub(['commands']), { type: 'startRecording' }));
    await assertSucceeds(deleteDoc(rec));
    await assertSucceeds(deleteDoc(sessionDoc()));
  });
});

describe('other collections', () => {
  test('app: clock probes are written, read back and deleted', async () => {
    const probe = doc(collection(db, '_clock_probes'));
    await assertSucceeds(setDoc(probe, { t: serverTimestamp(), expiresAt: inHours(24 * 7) }));
    await assertSucceeds(getDoc(probe));
    await assertSucceeds(deleteDoc(probe));
  });

  test('clock probes cannot be listed or hold other data', async () => {
    await assertFails(getDocs(collection(db, '_clock_probes')));
    await assertFails(setDoc(doc(collection(db, '_clock_probes')), { t: serverTimestamp(), x: 1 }));
  });

  test('collections the app does not use are denied', async () => {
    await assertFails(setDoc(doc(db, 'anything', 'x'), { a: 1 }));
    await assertFails(getDoc(doc(db, 'users', 'x')));
  });
});
