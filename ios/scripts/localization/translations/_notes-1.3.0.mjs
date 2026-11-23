#!/usr/bin/env node
/**
 * Release notes for 1.3.0, in all 21 storefront locales.
 *
 * 1.3.0 adds a swipe review for Live Photo conversion (every marked photo is
 * converted in one batch, so iOS asks once), the Text Photos tool (old photos
 * full of text), sort options in every Cleanup tool, and a Largest First deck
 * on the Swipe tab.
 *
 * The notes name no swipe direction: right and left swap in Arabic and Hebrew.
 * Tool, tab and deck names are the app's own translations from
 * Localizable.xcstrings. The closing sentence is the 1.2.1 one in every
 * language. "TidyByte", "iOS" and "Live Photos" stay Latin.
 *
 * App Store Connect allows 4000 characters; every value below is far under.
 *
 * Machine-drafted, like the rest of the store copy: not a native review pass.
 *
 * Run from ios/: node scripts/localization/translations/_notes-1.3.0.mjs
 */

import { readFileSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const LISTINGS = join(ROOT, 'docs', 'appstore', 'listings.json');
const LIMIT = 4000;

const NOTES = {
  en: "Review Live Photos with swipes, then convert the ones you pick to stills in one go, with a single iOS prompt. The new Text Photos tool finds old notes, tickets and receipts full of text that are likely out of date. Cleanup tools can now sort by size, date and more, and the Swipe tab has a new Largest First deck. Everything still runs on your device: no account, no ads, no subscription.",
  hi: "Live Photos को स्वाइप करके देखें, फिर चुनी हुई फ़ोटो को एक साथ स्टिल में कन्वर्ट करें, सिर्फ़ एक iOS प्रॉम्प्ट के साथ। नया टेक्स्ट वाली फ़ोटो टूल टेक्स्ट से भरे पुराने नोट, टिकट और रसीदें ढूँढता है, जो शायद अब काम के नहीं हैं। क्लीनअप टूल अब आकार, तारीख और दूसरे क्रम से छाँट सकते हैं, और स्वाइप टैब में नया सबसे बड़े पहले डेक है। सब कुछ अब भी आपके डिवाइस पर ही चलता है: कोई अकाउंट नहीं, कोई विज्ञापन नहीं, कोई सब्सक्रिप्शन नहीं।",
  bn: "সোয়াইপ করে Live Photos দেখুন, তারপর বেছে নেওয়া ছবিগুলো একসাথে স্থির ছবিতে রূপান্তর করুন, মাত্র একটি iOS প্রম্পটে। নতুন লেখাযুক্ত ছবি টুল লেখায় ভরা পুরোনো নোট, টিকিট আর রসিদ খুঁজে দেয়, যেগুলো সম্ভবত আর কাজের নয়। পরিষ্কার টুলগুলো এখন আকার, তারিখ ও আরও নানা ক্রমে সাজাতে পারে, আর সোয়াইপ ট্যাবে নতুন সবচেয়ে বড় আগে ডেক আছে। সবকিছু আগের মতোই আপনার ডিভাইসেই চলে: কোনো অ্যাকাউন্ট নেই, বিজ্ঞাপন নেই, সাবস্ক্রিপশন নেই।",
  ta: "Live Photos-ஐ ஸ்வைப் செய்து பாருங்கள், பிறகு நீங்கள் தேர்ந்தெடுத்தவற்றை ஒரே iOS கோரிக்கையுடன் ஒரே நேரத்தில் நிலைப்படங்களாக மாற்றுங்கள். புதிய உரைப் புகைப்படங்கள் கருவி, உரை நிறைந்த பழைய குறிப்புகள், டிக்கெட்டுகள், ரசீதுகளைக் கண்டறிகிறது; அவை பெரும்பாலும் இப்போது தேவையற்றவை. சுத்தம் கருவிகள் இப்போது அளவு, தேதி மற்றும் பலவற்றின்படி வரிசைப்படுத்தலாம், ஸ்வைப் தாவலில் புதிய பெரியவை முதலில் தொகுப்பும் உள்ளது. எல்லாமே இன்னும் உங்கள் சாதனத்திலேயே இயங்குகிறது: கணக்கு இல்லை, விளம்பரம் இல்லை, சந்தா இல்லை.",
  te: "Live Photosను స్వైప్ చేసి చూడండి, ఆపై మీరు ఎంచుకున్నవాటిని ఒకే iOS ప్రాంప్ట్‌తో ఒకేసారి స్థిర చిత్రాలుగా మార్చండి. కొత్త టెక్స్ట్ ఫోటోలు సాధనం టెక్స్ట్‌తో నిండిన పాత నోట్స్, టికెట్లు, రసీదులను కనుగొంటుంది, అవి బహుశా ఇప్పుడు అవసరం లేనివి. క్లీన్అప్ సాధనాలు ఇప్పుడు పరిమాణం, తేదీ వంటి క్రమాల్లో అమర్చగలవు, స్వైప్ ట్యాబ్‌లో కొత్త పెద్దవి మొదట డెక్ ఉంది. అన్నీ ఇప్పటికీ మీ పరికరంలోనే నడుస్తాయి: ఖాతా లేదు, ప్రకటనలు లేవు, సబ్‌స్క్రిప్షన్ లేదు.",
  mr: "Live Photos स्वाइप करून पाहा, मग निवडलेले फोटो एकाच iOS प्रॉम्प्टसह एकाच वेळी स्टिलमध्ये रूपांतरित करा. नवीन मजकूर असलेले फोटो साधन मजकुराने भरलेल्या जुन्या नोंदी, तिकिटे आणि पावत्या शोधते, ज्या बहुधा आता उपयोगाच्या नाहीत. क्लीनअप साधने आता आकार, तारीख आणि इतर क्रमाने लावू शकतात, आणि स्वाइप टॅबमध्ये नवीन सर्वात मोठे आधी डेक आहे. सगळे काही अजूनही तुमच्या डिव्हाइसवरच चालते: खाते नाही, जाहिराती नाहीत, सबस्क्रिप्शन नाही.",
  gu: "Live Photos સ્વાઇપ કરીને જુઓ, પછી પસંદ કરેલાને એક જ iOS પ્રોમ્પ્ટ સાથે એકસાથે સ્ટિલમાં કન્વર્ટ કરો. નવું લખાણવાળા ફોટા ટૂલ લખાણથી ભરેલી જૂની નોંધો, ટિકિટો અને રસીદો શોધે છે, જે કદાચ હવે કામની નથી. ક્લીનઅપ ટૂલ હવે કદ, તારીખ અને વધુ ક્રમમાં ગોઠવી શકે છે, અને સ્વાઇપ ટૅબમાં નવું સૌથી મોટા પહેલા ડેક છે. બધું હજુ પણ તમારા ડિવાઇસ પર જ ચાલે છે: કોઈ એકાઉન્ટ નહીં, કોઈ જાહેરાત નહીં, કોઈ સબ્સ્ક્રિપ્શન નહીં.",
  kn: "Live Photos ಅನ್ನು ಸ್ವೈಪ್ ಮಾಡಿ ನೋಡಿ, ನಂತರ ಆಯ್ಕೆ ಮಾಡಿದವನ್ನು ಒಂದೇ iOS ಪ್ರಾಂಪ್ಟ್‌ನೊಂದಿಗೆ ಒಮ್ಮೆಲೇ ಸ್ಟಿಲ್‌ಗಳಾಗಿ ಪರಿವರ್ತಿಸಿ. ಹೊಸ ಪಠ್ಯವಿರುವ ಫೋಟೋಗಳು ಸಾಧನವು ಪಠ್ಯ ತುಂಬಿದ ಹಳೆಯ ಟಿಪ್ಪಣಿಗಳು, ಟಿಕೆಟ್‌ಗಳು ಮತ್ತು ರಸೀದಿಗಳನ್ನು ಹುಡುಕುತ್ತದೆ, ಅವು ಬಹುಶಃ ಈಗ ಬೇಕಿಲ್ಲ. ಕ್ಲೀನ್ಅಪ್ ಸಾಧನಗಳು ಈಗ ಗಾತ್ರ, ದಿನಾಂಕ ಮತ್ತು ಇನ್ನಷ್ಟು ಕ್ರಮದಲ್ಲಿ ಜೋಡಿಸಬಲ್ಲವು, ಮತ್ತು ಸ್ವೈಪ್ ಟ್ಯಾಬ್‌ನಲ್ಲಿ ಹೊಸ ಅತಿದೊಡ್ಡವು ಮೊದಲು ಡೆಕ್ ಇದೆ. ಎಲ್ಲವೂ ಈಗಲೂ ನಿಮ್ಮ ಸಾಧನದಲ್ಲೇ ನಡೆಯುತ್ತದೆ: ಖಾತೆ ಇಲ್ಲ, ಜಾಹೀರಾತು ಇಲ್ಲ, ಚಂದಾದಾರಿಕೆ ಇಲ್ಲ.",
  ml: "Live Photos സ്വൈപ്പ് ചെയ്ത് നോക്കുക, തുടർന്ന് തിരഞ്ഞെടുത്തവ ഒരൊറ്റ iOS പ്രോംപ്റ്റോടെ ഒരുമിച്ച് സ്റ്റില്ലുകളാക്കി മാറ്റുക. പുതിയ ടെക്സ്റ്റ് ഫോട്ടോകൾ ടൂൾ ടെക്സ്റ്റ് നിറഞ്ഞ പഴയ കുറിപ്പുകളും ടിക്കറ്റുകളും രസീതുകളും കണ്ടെത്തുന്നു, അവ ഇപ്പോൾ ആവശ്യമില്ലാത്തവയാകാം. ക്ലീനപ്പ് ടൂളുകൾക്ക് ഇപ്പോൾ വലുപ്പം, തീയതി എന്നിങ്ങനെ ക്രമീകരിക്കാം, സ്വൈപ്പ് ടാബിൽ പുതിയ ഏറ്റവും വലിയത് ആദ്യം ഡെക്കുമുണ്ട്. എല്ലാം ഇപ്പോഴും നിങ്ങളുടെ ഉപകരണത്തിൽ തന്നെ പ്രവർത്തിക്കുന്നു: അക്കൗണ്ടില്ല, പരസ്യങ്ങളില്ല, സബ്സ്ക്രിപ്ഷനില്ല.",
  pa: "Live Photos ਨੂੰ ਸਵਾਈਪ ਕਰਕੇ ਵੇਖੋ, ਫਿਰ ਚੁਣੀਆਂ ਹੋਈਆਂ ਨੂੰ ਸਿਰਫ਼ ਇੱਕ iOS ਪ੍ਰੌਂਪਟ ਨਾਲ ਇੱਕੋ ਵਾਰ ਸਥਿਰ ਫ਼ੋਟੋਆਂ ਵਿੱਚ ਬਦਲੋ। ਨਵਾਂ ਲਿਖਤ ਵਾਲੀਆਂ ਫ਼ੋਟੋਆਂ ਟੂਲ ਲਿਖਤ ਨਾਲ ਭਰੇ ਪੁਰਾਣੇ ਨੋਟ, ਟਿਕਟਾਂ ਅਤੇ ਰਸੀਦਾਂ ਲੱਭਦਾ ਹੈ, ਜੋ ਸ਼ਾਇਦ ਹੁਣ ਕੰਮ ਦੀਆਂ ਨਹੀਂ। ਸਫ਼ਾਈ ਟੂਲ ਹੁਣ ਆਕਾਰ, ਤਾਰੀਖ਼ ਅਤੇ ਹੋਰ ਕ੍ਰਮ ਵਿੱਚ ਲਗਾ ਸਕਦੇ ਹਨ, ਅਤੇ ਸਵਾਈਪ ਟੈਬ ਵਿੱਚ ਨਵਾਂ ਸਭ ਤੋਂ ਵੱਡੇ ਪਹਿਲਾਂ ਡੈੱਕ ਹੈ। ਸਭ ਕੁਝ ਅਜੇ ਵੀ ਤੁਹਾਡੇ ਡਿਵਾਈਸ 'ਤੇ ਹੀ ਚੱਲਦਾ ਹੈ: ਕੋਈ ਖਾਤਾ ਨਹੀਂ, ਕੋਈ ਇਸ਼ਤਿਹਾਰ ਨਹੀਂ, ਕੋਈ ਸਬਸਕ੍ਰਿਪਸ਼ਨ ਨਹੀਂ।",
  es: "Revisa tus Live Photos deslizando y convierte las que elijas en fotos fijas de una vez, con un solo aviso de iOS. La nueva herramienta Fotos con texto encuentra notas, entradas y recibos antiguos llenos de texto que probablemente ya no sirven. Las herramientas de Limpieza ahora ordenan por tamaño, fecha y más, y la pestaña Deslizar tiene un nuevo mazo Más grandes primero. Todo sigue funcionando en tu dispositivo: sin cuenta, sin anuncios, sin suscripción.",
  fr: "Passez en revue vos Live Photos en balayant, puis convertissez celles que vous choisissez en photos fixes d’un coup, avec une seule alerte iOS. Le nouvel outil Photos de texte trouve les anciennes notes, billets et reçus remplis de texte, sans doute périmés. Les outils de Nettoyage peuvent désormais trier par taille, par date et plus encore, et l’onglet Balayer propose un nouveau paquet Les plus volumineux d’abord. Tout fonctionne toujours sur votre appareil : sans compte, sans publicité, sans abonnement.",
  de: "Prüfe Live Photos per Wischen und konvertiere die ausgewählten in einem Schritt zu Standbildern, mit nur einer iOS-Abfrage. Das neue Werkzeug Textfotos findet alte Notizen, Tickets und Belege voller Text, die wahrscheinlich veraltet sind. Die Bereinigungswerkzeuge sortieren jetzt nach Größe, Datum und mehr, und der Tab Wischen hat einen neuen Stapel Größte zuerst. Alles läuft weiterhin auf deinem Gerät: kein Konto, keine Werbung, kein Abo.",
  "pt-BR": "Revise suas Live Photos deslizando e converta as que escolher em fotos estáticas de uma vez, com um único aviso do iOS. A nova ferramenta Fotos com texto encontra notas, ingressos e recibos antigos cheios de texto que provavelmente estão desatualizados. As ferramentas de Limpeza agora ordenam por tamanho, data e mais, e a aba Deslizar tem um novo baralho Maiores primeiro. Tudo continua rodando no seu aparelho: sem conta, sem anúncios, sem assinatura.",
  it: "Rivedi le Live Photo scorrendo e converti quelle che scegli in foto statiche in un colpo solo, con un’unica richiesta di iOS. Il nuovo strumento Foto con testo trova vecchi appunti, biglietti e ricevute pieni di testo, probabilmente non più attuali. Gli strumenti di Pulizia ora ordinano per dimensione, data e altro, e la scheda Scorri ha un nuovo mazzo Prima i più grandi. Tutto funziona ancora sul tuo dispositivo: nessun account, nessuna pubblicità, nessun abbonamento.",
  ja: "Live Photoをスワイプで確認し、選んだものを1回のiOSの確認だけでまとめて静止画に変換できます。新しい「テキストの写真」ツールは、すでに古くなっていそうな、文字の多いメモ、チケット、レシートの写真を見つけます。クリーンアップの各ツールはサイズや日付などで並べ替えられるようになり、スワイプタブには新しい「大きい順」のデッキが加わりました。これまでどおり、すべてデバイス上で動作します。アカウント不要、広告なし、サブスクリプションなし。",
  ko: "Live Photo를 스와이프로 검토하고, 고른 사진을 iOS 확인 한 번으로 한꺼번에 스틸 사진으로 변환하세요. 새로운 텍스트 사진 도구는 이미 쓸모없어졌을 가능성이 높은, 텍스트가 많은 오래된 메모, 티켓, 영수증 사진을 찾아 줍니다. 정리 도구는 이제 크기, 날짜 등으로 정렬할 수 있고, 스와이프 탭에는 새로운 용량순 덱이 추가되었습니다. 모든 작업은 여전히 기기에서만 실행됩니다. 계정, 광고, 구독이 없습니다.",
  "zh-Hans": "现在可以滑动查看 Live Photos，再将选中的照片一次性转换为静态照片，只需确认一次 iOS 提示。全新的“文字照片”工具会找出满是文字、很可能已经过时的旧笔记、票据和收据。清理工具现在可以按大小、日期等排序，滑动标签页还新增了“从大到小”卡组。一切仍在你的设备上运行：无需账户，没有广告，没有订阅。",
  ru: "Просматривайте Live Photos свайпами и превращайте выбранные в обычные фото за один раз, всего с одним запросом iOS. Новый инструмент «Фото с текстом» находит старые заметки, билеты и чеки, полные текста, которые, скорее всего, уже неактуальны. Инструменты очистки теперь сортируют по размеру, дате и другим признакам, а во вкладке «Свайп» появилась новая колода «Сначала большие». Всё по-прежнему работает на вашем устройстве: без аккаунта, без рекламы, без подписки.",
  ar: "راجع صور Live Photos بالسحب، ثم حوّل الصور التي تختارها إلى صور ثابتة دفعة واحدة، مع طلب iOS واحد فقط. تعثر أداة صور النصوص الجديدة على الملاحظات والتذاكر والإيصالات القديمة المليئة بالنصوص والتي ربما لم تعد مفيدة. يمكن لأدوات التنظيف الآن الفرز حسب الحجم والتاريخ وغير ذلك، ويضم تبويب السحب مجموعة جديدة باسم الأكبر أولًا. كل شيء ما زال يعمل على جهازك: بلا حساب، بلا إعلانات، بلا اشتراك.",
  he: "אפשר לעבור על תמונות Live Photos בהחלקה ולהמיר את אלה שבחרת לתמונות רגילות בבת אחת, עם בקשת iOS אחת בלבד. הכלי החדש תמונות טקסט מוצא פתקים, כרטיסים וקבלות ישנים מלאי טקסט שכנראה כבר לא רלוונטיים. כלי הניקוי יכולים עכשיו למיין לפי גודל, תאריך ועוד, ובלשונית החלקה יש חפיסה חדשה של הגדולים קודם. הכול עדיין רץ במכשיר שלך: בלי חשבון, בלי פרסומות, בלי מנוי.",
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
