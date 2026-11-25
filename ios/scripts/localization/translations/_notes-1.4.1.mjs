#!/usr/bin/env node
/**
 * Release notes for 1.4.1, in all 21 storefront locales.
 *
 * 1.4.1 shows photos sharp on the comparison screens of Duplicates and
 * Similar Photos (#44): they could show a blurred, small cached copy. It also
 * adds Select to each group in Duplicates, which marks every copy except the
 * keeper (#45).
 *
 * Tool names and Select are the app's own translations from
 * Localizable.xcstrings. The closing sentence is the 1.4.0 one in every
 * language. "TidyByte" stays Latin.
 *
 * App Store Connect allows 4000 characters; every value below is far under.
 *
 * Machine-drafted, like the rest of the store copy: not a native review pass.
 *
 * Run from ios/: node scripts/localization/translations/_notes-1.4.1.mjs
 */

import { readFileSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const LISTINGS = join(ROOT, 'docs', 'appstore', 'listings.json');
const LIMIT = 4000;

const NOTES = {
  en: "When you compare photos in Duplicates and Similar Photos, they are now sharp, the same as in the full-screen view. In Duplicates, a new Select button on each group marks every copy except the one you keep. Everything still runs on your device: no account, no ads, no subscription.",
  hi: "डुप्लिकेट और मिलती-जुलती फ़ोटो में तुलना करते समय फ़ोटो अब साफ़ दिखती हैं, ठीक फ़ुल-स्क्रीन व्यू की तरह। डुप्लिकेट में हर समूह पर नया चुनें बटन, रखी जाने वाली फ़ोटो को छोड़कर, सभी कॉपी चिह्नित करता है। सब कुछ अब भी आपके डिवाइस पर ही चलता है: कोई अकाउंट नहीं, कोई विज्ञापन नहीं, कोई सब्सक्रिप्शन नहीं।",
  bn: "ডুপ্লিকেট আর একইরকম ফটো-তে তুলনা করার সময় ফটো এখন স্পষ্ট দেখায়, ঠিক পুরো স্ক্রিনের মতো। ডুপ্লিকেট-এ প্রতিটি গ্রুপের নতুন নির্বাচন করুন বোতাম, যেটি রাখবেন সেটি ছাড়া, সব কপি চিহ্নিত করে। সবকিছু আগের মতোই আপনার ডিভাইসেই চলে: কোনো অ্যাকাউন্ট নেই, বিজ্ঞাপন নেই, সাবস্ক্রিপশন নেই।",
  ta: "நகல்கள் மற்றும் ஒத்த புகைப்படங்களில் ஒப்பிடும்போது புகைப்படங்கள் இப்போது முழுத் திரைக் காட்சியைப் போலவே தெளிவாகத் தெரியும். நகல்களில், ஒவ்வொரு குழுவிலும் உள்ள புதிய தேர்ந்தெடு பொத்தான், நீங்கள் வைத்திருக்கும் புகைப்படம் தவிர எல்லா நகல்களையும் குறிக்கும். எல்லாமே இன்னும் உங்கள் சாதனத்திலேயே இயங்குகிறது: கணக்கு இல்லை, விளம்பரம் இல்லை, சந்தா இல்லை.",
  te: "నకిలీలు మరియు సమానమైన ఫోటోలలో పోల్చేటప్పుడు ఫోటోలు ఇప్పుడు పూర్తి స్క్రీన్ వీక్షణలాగే స్పష్టంగా కనిపిస్తాయి. నకిలీలలో, ప్రతి సమూహంపై ఉన్న కొత్త ఎంచుకోండి బటన్, మీరు ఉంచే ఫోటో తప్ప అన్ని కాపీలను గుర్తిస్తుంది. అన్నీ ఇప్పటికీ మీ పరికరంలోనే నడుస్తాయి: ఖాతా లేదు, ప్రకటనలు లేవు, సబ్‌స్క్రిప్షన్ లేదు.",
  mr: "डुप्लिकेट आणि समान फोटो मध्ये तुलना करताना फोटो आता पूर्ण स्क्रीन दृश्याप्रमाणेच स्पष्ट दिसतात. डुप्लिकेट मध्ये प्रत्येक गटावरील नवीन निवडा बटण, तुम्ही ठेवायचा फोटो सोडून, सर्व प्रती चिन्हांकित करते. सगळे काही अजूनही तुमच्या डिव्हाइसवरच चालते: खाते नाही, जाहिराती नाहीत, सबस्क्रिप्शन नाही.",
  gu: "ડુપ્લિકેટ અને સમાન ફોટામાં તુલના કરતી વખતે ફોટા હવે ફુલ-સ્ક્રીન વ્યૂ જેટલા જ સ્પષ્ટ દેખાય છે. ડુપ્લિકેટમાં દરેક જૂથ પરનું નવું પસંદ કરો બટન, તમે રાખો તે ફોટા સિવાય, બધી નકલો ચિહ્નિત કરે છે. બધું હજુ પણ તમારા ડિવાઇસ પર જ ચાલે છે: કોઈ એકાઉન્ટ નહીં, કોઈ જાહેરાત નહીં, કોઈ સબ્સ્ક્રિપ્શન નહીં.",
  kn: "ನಕಲಿಗಳು ಮತ್ತು ಸಮಾನ ಫೋಟೋಗಳಲ್ಲಿ ಹೋಲಿಸುವಾಗ ಫೋಟೋಗಳು ಈಗ ಪೂರ್ಣ ಪರದೆಯ ವೀಕ್ಷಣೆಯಂತೆಯೇ ಸ್ಪಷ್ಟವಾಗಿ ಕಾಣುತ್ತವೆ. ನಕಲಿಗಳಲ್ಲಿ, ಪ್ರತಿ ಗುಂಪಿನ ಹೊಸ ಆಯ್ಕೆಮಾಡಿ ಬಟನ್, ನೀವು ಇರಿಸಿಕೊಳ್ಳುವ ಫೋಟೋ ಹೊರತುಪಡಿಸಿ ಎಲ್ಲಾ ಪ್ರತಿಗಳನ್ನು ಗುರುತಿಸುತ್ತದೆ. ಎಲ್ಲವೂ ಈಗಲೂ ನಿಮ್ಮ ಸಾಧನದಲ್ಲೇ ನಡೆಯುತ್ತದೆ: ಖಾತೆ ಇಲ್ಲ, ಜಾಹೀರಾತು ಇಲ್ಲ, ಚಂದಾದಾರಿಕೆ ಇಲ್ಲ.",
  ml: "ഡ്യൂപ്ലിക്കേറ്റുകളിലും സമാന ഫോട്ടോകളിലും താരതമ്യം ചെയ്യുമ്പോൾ ഫോട്ടോകൾ ഇപ്പോൾ ഫുൾ സ്ക്രീൻ കാഴ്ചയിലെന്നപോലെ വ്യക്തമായി കാണാം. ഡ്യൂപ്ലിക്കേറ്റുകളിൽ, ഓരോ ഗ്രൂപ്പിലെയും പുതിയ തിരഞ്ഞെടുക്കുക ബട്ടൺ, നിങ്ങൾ നിലനിർത്തുന്ന ഫോട്ടോ ഒഴികെ എല്ലാ പകർപ്പുകളും അടയാളപ്പെടുത്തുന്നു. എല്ലാം ഇപ്പോഴും നിങ്ങളുടെ ഉപകരണത്തിൽ തന്നെ പ്രവർത്തിക്കുന്നു: അക്കൗണ്ടില്ല, പരസ്യങ്ങളില്ല, സബ്സ്ക്രിപ്ഷനില്ല.",
  pa: "ਡੁਪਲੀਕੇਟ ਅਤੇ ਸਮਾਨ ਫ਼ੋਟੋਆਂ ਵਿੱਚ ਤੁਲਨਾ ਕਰਦੇ ਸਮੇਂ ਫ਼ੋਟੋਆਂ ਹੁਣ ਪੂਰੀ ਸਕ੍ਰੀਨ ਵਾਂਗ ਹੀ ਸਾਫ਼ ਦਿਸਦੀਆਂ ਹਨ। ਡੁਪਲੀਕੇਟ ਵਿੱਚ ਹਰ ਗਰੁੱਪ 'ਤੇ ਨਵਾਂ ਚੁਣੋ ਬਟਨ, ਤੁਹਾਡੇ ਵੱਲੋਂ ਰੱਖੀ ਫ਼ੋਟੋ ਨੂੰ ਛੱਡ ਕੇ, ਸਾਰੀਆਂ ਕਾਪੀਆਂ ਨਿਸ਼ਾਨਬੱਧ ਕਰਦਾ ਹੈ। ਸਭ ਕੁਝ ਅਜੇ ਵੀ ਤੁਹਾਡੇ ਡਿਵਾਈਸ 'ਤੇ ਹੀ ਚੱਲਦਾ ਹੈ: ਕੋਈ ਖਾਤਾ ਨਹੀਂ, ਕੋਈ ਇਸ਼ਤਿਹਾਰ ਨਹੀਂ, ਕੋਈ ਸਬਸਕ੍ਰਿਪਸ਼ਨ ਨਹੀਂ।",
  es: "Al comparar fotos en Duplicados y Fotos similares, ahora se ven nítidas, igual que a pantalla completa. En Duplicados, el nuevo botón Seleccionar de cada grupo marca todas las copias excepto la que conservas. Todo sigue funcionando en tu dispositivo: sin cuenta, sin anuncios, sin suscripción.",
  fr: "Quand vous comparez des photos dans Doublons et Photos similaires, elles sont désormais nettes, comme en plein écran. Dans Doublons, le nouveau bouton Sélectionner de chaque groupe marque toutes les copies sauf celle que vous gardez. Tout fonctionne toujours sur votre appareil : sans compte, sans publicité, sans abonnement.",
  de: "Beim Vergleichen unter Duplikate und Ähnliche Fotos sind Fotos jetzt scharf, genau wie in der Vollbildansicht. Unter Duplikate markiert die neue Schaltfläche Auswählen an jeder Gruppe alle Kopien außer der, die du behältst. Alles läuft weiterhin auf deinem Gerät: kein Konto, keine Werbung, kein Abo.",
  "pt-BR": "Ao comparar fotos em Duplicatas e Fotos semelhantes, elas agora aparecem nítidas, como em tela cheia. Em Duplicatas, o novo botão Selecionar de cada grupo marca todas as cópias, exceto a que você vai manter. Tudo continua rodando no seu aparelho: sem conta, sem anúncios, sem assinatura.",
  it: "Quando confronti le foto in Duplicati e Foto simili, ora sono nitide, come a schermo intero. In Duplicati, il nuovo pulsante Seleziona di ogni gruppo segna tutte le copie tranne quella che tieni. Tutto funziona ancora sul tuo dispositivo: nessun account, nessuna pubblicità, nessun abbonamento.",
  ja: "「重複」と「類似した写真」で写真を比較するとき、フルスクリーン表示と同じように鮮明に表示されるようになりました。「重複」では、各グループの新しい「選択」ボタンで、残す写真以外のすべてのコピーを削除対象にできます。これまでどおり、すべてデバイス上で動作します。アカウント不要、広告なし、サブスクリプションなし。",
  ko: "중복 항목과 비슷한 사진에서 사진을 비교할 때 이제 전체 화면처럼 선명하게 보입니다. 중복 항목에서는 각 그룹의 새로운 선택 버튼으로 남길 사진을 제외한 모든 사본을 표시할 수 있습니다. 모든 작업은 여전히 기기에서만 실행됩니다. 계정, 광고, 구독이 없습니다.",
  "zh-Hans": "在“重复项”和“相似照片”中比较照片时，照片现在会像全屏查看时一样清晰。在“重复项”中，每个组上新的“选择”按钮会标记除保留照片外的所有副本。一切仍在你的设备上运行：无需账户，没有广告，没有订阅。",
  ru: "При сравнении фото в разделах «Дубликаты» и «Похожие фото» они теперь чёткие, как на весь экран. В «Дубликатах» новая кнопка «Выбрать» у каждой группы помечает все копии, кроме той, которую вы оставляете. Всё по-прежнему работает на вашем устройстве: без аккаунта, без рекламы, без подписки.",
  ar: "عند مقارنة الصور في «المكررات» و«الصور المشابهة» أصبحت الآن واضحة، تمامًا كما في العرض بملء الشاشة. في «المكررات»، يحدد زر «تحديد» الجديد في كل مجموعة كل النسخ باستثناء الصورة التي تحتفظ بها. كل شيء ما زال يعمل على جهازك: بلا حساب، بلا إعلانات، بلا اشتراك.",
  he: "כשמשווים תמונות במסכי כפולים ותמונות דומות, הן נראות עכשיו חדות, בדיוק כמו במסך מלא. בכפולים, הכפתור החדש בחר בכל קבוצה מסמן את כל העותקים חוץ מזה שנשמר. הכול עדיין רץ במכשיר שלך: בלי חשבון, בלי פרסומות, בלי מנוי.",
};

const listings = JSON.parse(readFileSync(LISTINGS, 'utf8'));
const languages = Object.keys(listings).filter((key) => !key.startsWith('_'));

// Measure everything before writing, so an over-length value cannot land.
let bad = 0;
for (const language of languages) {
  const value = NOTES[language];
  if (value === undefined) {
    console.error(`FAIL: no release notes for ${language}`);
    bad += 1;
    continue;
  }
  const length = [...value].length;
  if (length > LIMIT) {
    console.error(`FAIL: ${language} is ${length} chars, limit is ${LIMIT}`);
    bad += 1;
  }
}
if (bad > 0) {
  console.error(`\n${bad} problem(s). Nothing written.`);
  process.exit(1);
}

for (const language of languages) {
  const before = listings[language].whatsNew;
  listings[language].whatsNew = NOTES[language];
  const length = [...NOTES[language]].length;
  const changed = before === NOTES[language] ? '  (unchanged)' : '';
  console.log(`${language.padEnd(9)} ${String(length).padStart(4)}/${LIMIT}${changed}`);
}

writeFileSync(LISTINGS, `${JSON.stringify(listings, null, 2)}\n`);
console.log(`\n${languages.length} release note(s) written.`);
