// اختبار قواعد Firestore على المحاكي: cd firebase/test && npm i && npm test
import { initializeTestEnvironment, assertSucceeds, assertFails } from '@firebase/rules-unit-testing';
import { doc, setDoc, getDoc, updateDoc, writeBatch, serverTimestamp, getDocs, collection, Timestamp, deleteDoc } from 'firebase/firestore';
import fs from 'fs';

const env = await initializeTestEnvironment({
  projectId: 'demo-nasaq',
  firestore: { rules: fs.readFileSync(new URL('../firestore.rules', import.meta.url), 'utf8'), host: '127.0.0.1', port: 8080 },
});
let pass = 0, fail = 0;
async function t(name, fn) {
  try { await fn(); pass++; console.log('  ok  ', name); }
  catch (e) { fail++; console.log('  FAIL', name, '\n      ', String(e).split('\n')[0]); }
}
const user = (uid, email = `${uid}@gmail.com`) =>
  env.authenticatedContext(uid, { email, email_verified: true }).firestore();
const seedCode = (h, plan = '6m', status = 'available') =>
  env.withSecurityRulesDisabled(async (c) => setDoc(doc(c.firestore(), 'codes', h), { plan, agent: 'A', batch: 'b', status }));
const seedLic = (uid, data) =>
  env.withSecurityRulesDisabled(async (c) => setDoc(doc(c.firestore(), 'licenses', uid), data));
const days = (n) => Timestamp.fromMillis(Date.now() - n * 86400000);

function redeemBatch(db, uid, h, licData, create) {
  const b = writeBatch(db);
  const lic = doc(db, 'licenses', uid);
  if (create) b.set(lic, licData); else b.update(lic, licData);
  b.update(doc(db, 'codes', h), { status: 'redeemed', redeemedBy: uid, redeemedAt: serverTimestamp() });
  return b.commit();
}
const first = (uid, h, plan) => ({
  email: `${uid}@gmail.com`, deviceId: 'D1', activatedAt: serverTimestamp(), windowStart: serverTimestamp(),
  transferCount: 0, startedAt: serverTimestamp(), days: plan === 'life' ? 0 : plan === '6m' ? 183 : 365,
  lifetime: plan === 'life', lastCode: h,
});

await env.clearFirestore();

console.log('أول تفعيل');
await seedCode('h6'); await seedCode('h12', '12m'); await seedCode('hlife', 'life');
await t('كود 6 أشهر يُنشئ ترخيصاً', () => assertSucceeds(redeemBatch(user('u1'), 'u1', 'h6', first('u1', 'h6', '6m'), true)));
await t('الكود المستهلك لا يُستعمل ثانية (مستخدم آخر)', () => assertFails(redeemBatch(user('u2'), 'u2', 'h6', first('u2', 'h6', '6m'), true)));
await t('لا ترخيص بلا استهلاك كود', async () => assertFails(setDoc(doc(user('u3'), 'licenses', 'u3'), first('u3', 'hx', '6m'))));
await seedCode('hb', '6m');
await t('لا ترخيص بأيام مضاعفة', () => assertFails(redeemBatch(user('u4'), 'u4', 'hb', { ...first('u4', 'hb', '6m'), days: 3650 }, true)));
await t('لا ترخيص lifetime بكود 6 أشهر', () => assertFails(redeemBatch(user('u4'), 'u4', 'hb', { ...first('u4', 'hb', '6m'), lifetime: true }, true)));
await t('لا ترخيص لحساب آخر', () => assertFails(redeemBatch(user('u4'), 'u9', 'hb', first('u9', 'hb', '6m'), true)));
await t('لا استهلاك للكود بدون ترخيص مع إيميل مزوّر', () => assertFails(redeemBatch(user('u4'), 'u4', 'hb', { ...first('u4', 'hb', '6m'), email: 'x@y.com' }, true)));
await t('كود سنة', () => assertSucceeds(redeemBatch(user('u5'), 'u5', 'h12', first('u5', 'h12', '12m'), true)));
await t('كود مدى الحياة', () => assertSucceeds(redeemBatch(user('u6'), 'u6', 'hlife', first('u6', 'hlife', 'life'), true)));
await t('بريد غير موثّق مرفوض', async () => {
  const db = env.authenticatedContext('u7', { email: 'u7@gmail.com', email_verified: false }).firestore();
  await seedCode('hv');
  await assertFails(redeemBatch(db, 'u7', 'hv', first('u7', 'hv', '6m'), true));
});
await t('بلا تسجيل دخول مرفوض', async () => {
  const db = env.unauthenticatedContext().firestore();
  await assertFails(getDoc(doc(db, 'codes', 'hv')));
});

console.log('القراءة والكتابة المباشرة');
await t('قراءة ترخيصي', () => assertSucceeds(getDoc(doc(user('u1'), 'licenses', 'u1'))));
await t('منع قراءة ترخيص غيري', () => assertFails(getDoc(doc(user('u2'), 'licenses', 'u1'))));
await t('منع سرد التراخيص', () => assertFails(getDocs(collection(user('u1'), 'licenses'))));
await t('منع سرد الأكواد', () => assertFails(getDocs(collection(user('u1'), 'codes'))));
await t('منع إنشاء كود من العميل', () => assertFails(setDoc(doc(user('u1'), 'codes', 'new'), { plan: 'life', status: 'available' })));
await t('منع حذف كود/ترخيص', async () => { await assertFails(deleteDoc(doc(user('u1'), 'licenses', 'u1'))); await assertFails(deleteDoc(doc(user('u1'), 'codes', 'h6'))); });
await t('منع تعديل الأيام مباشرة بلا كود', () => assertFails(updateDoc(doc(user('u1'), 'licenses', 'u1'), { days: 99999 })));
await t('منع تحويل ترخيصي إلى lifetime بلا كود', () => assertFails(updateDoc(doc(user('u1'), 'licenses', 'u1'), { lifetime: true })));
await t('منع إعادة تفعيل كود مستخدم بتعديله', () => assertFails(updateDoc(doc(user('u1'), 'codes', 'h6'), { status: 'available' })));

console.log('التمديد');
await seedCode('e1', '6m'); await seedCode('e2', '12m'); await seedCode('e3', 'life'); await seedCode('e4', '6m');
await t('تمديد ساري يجمع الأيام (183+365)', () => assertSucceeds(redeemBatch(user('u1'), 'u1', 'e2', { days: 183 + 365, lastCode: 'e2' }, false)));
await t('تمديد ساري بأيام خاطئة مرفوض', () => assertFails(redeemBatch(user('u1'), 'u1', 'e1', { days: 999999, lastCode: 'e1' }, false)));
await t('تمديد ساري بإعادة ضبط startedAt مرفوض', () => assertFails(redeemBatch(user('u1'), 'u1', 'e1', { days: 183, startedAt: serverTimestamp(), lastCode: 'e1' }, false)));
await seedLic('ux', { email: 'ux@gmail.com', deviceId: 'D1', activatedAt: days(300), windowStart: days(300), transferCount: 0, startedAt: days(300), days: 183, lifetime: false, lastCode: 'old' });
await seedCode('x1', '6m'); await seedCode('x2', '6m');
await t('تمديد بعد الانتهاء يبدأ فترة جديدة', () => assertSucceeds(redeemBatch(user('ux'), 'ux', 'x1', { startedAt: serverTimestamp(), days: 183, lastCode: 'x1' }, false)));
await seedLic('ux2', { email: 'ux2@gmail.com', deviceId: 'D1', activatedAt: days(300), windowStart: days(300), transferCount: 0, startedAt: days(300), days: 183, lifetime: false, lastCode: 'old' });
await t('بعد الانتهاء: جمع الأيام بدل البدء من جديد مرفوض', () => assertFails(redeemBatch(user('ux2'), 'ux2', 'x2', { days: 366, lastCode: 'x2' }, false)));
await t('ترقية إلى مدى الحياة بكود lifetime', () => assertSucceeds(redeemBatch(user('u1'), 'u1', 'e3', { lifetime: true, lastCode: 'e3' }, false)));
await t('بعد lifetime لا تمديد آخر', () => assertFails(redeemBatch(user('u1'), 'u1', 'e4', { days: 999, lastCode: 'e4' }, false)));
await t('تمديد من جهاز مختلف مرفوض (يجب النقل أولاً)', async () => {
  await seedCode('e5', '6m');
  await assertFails(redeemBatch(user('u5'), 'u5', 'e5', { days: 365 + 183, deviceId: 'OTHER', lastCode: 'e5' }, false));
});
await t('استعمال نفس الكود مرتين على الترخيص نفسه مرفوض', async () => {
  await seedCode('e6', '6m');
  await assertSucceeds(redeemBatch(user('u5'), 'u5', 'e6', { days: 365 + 183, lastCode: 'e6' }, false));
  await assertFails(redeemBatch(user('u5'), 'u5', 'e6', { days: 365 + 183 + 183, lastCode: 'e6' }, false));
});

console.log('نقل الجهاز');
await seedLic('t1', { email: 't1@gmail.com', deviceId: 'A', activatedAt: days(1), windowStart: days(1), transferCount: 0, startedAt: days(1), days: 183, lifetime: false, lastCode: 'o' });
const tr = (db, uid, dev, count) => updateDoc(doc(db, 'licenses', uid), { deviceId: dev, activatedAt: serverTimestamp(), transferCount: count });
await t('نقل 1', () => assertSucceeds(tr(user('t1'), 't1', 'B', 1)));
await t('نقل 2', () => assertSucceeds(tr(user('t1'), 't1', 'C', 2)));
await t('نقل 3', () => assertSucceeds(tr(user('t1'), 't1', 'D', 3)));
await t('نقل 4 داخل 30 يوماً مرفوض', () => assertFails(tr(user('t1'), 't1', 'E', 4)));
await t('تصفير العداد دون انتهاء النافذة مرفوض', () => assertFails(updateDoc(doc(user('t1'), 'licenses', 't1'), { deviceId: 'E', activatedAt: serverTimestamp(), transferCount: 1, windowStart: serverTimestamp() })));
await t('النقل لا يغيّر الاشتراك (days)', async () => {
  await seedLic('t3', { email: 't3@gmail.com', deviceId: 'A', activatedAt: days(1), windowStart: days(1), transferCount: 0, startedAt: days(1), days: 183, lifetime: false, lastCode: 'o' });
  await assertFails(updateDoc(doc(user('t3'), 'licenses', 't3'), { deviceId: 'B', activatedAt: serverTimestamp(), transferCount: 1, days: 99999 }));
});
await seedLic('t2', { email: 't2@gmail.com', deviceId: 'A', activatedAt: days(40), windowStart: days(40), transferCount: 3, startedAt: days(40), days: 183, lifetime: false, lastCode: 'o' });
await t('بعد انتهاء النافذة يُسمح وبعدّاد جديد', () => assertSucceeds(updateDoc(doc(user('t2'), 'licenses', 't2'), { deviceId: 'B', activatedAt: serverTimestamp(), transferCount: 1, windowStart: serverTimestamp() })));
await t('نقل ترخيص غيري مرفوض', () => assertFails(tr(user('u2'), 't2', 'Z', 2)));

console.log(`\nالنتيجة: ${pass} نجح، ${fail} فشل`);
await env.cleanup();
process.exit(fail ? 1 : 0);
