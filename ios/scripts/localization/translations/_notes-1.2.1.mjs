#!/usr/bin/env node
/**
 * Release notes for 1.2.1, in all 21 storefront locales.
 *
 * 1.2.1 fixes slow and stuck loading on large libraries (about 27,000 items in
 * the report): the resource cache is no longer cleared by library changes, it
 * is kept on disk between launches, photos swiped past stop downloading from
 * iCloud, and the exact duplicate scan reads far fewer files. See
 * docs/large-library-performance.md.
 *
 * The tab names (Storage, Cleanup) are the app's own translations from
 * Localizable.xcstrings. The closing sentence is the 1.2.0 one in every
 * language. "TidyByte" and "iCloud" stay Latin.
 *
 * App Store Connect allows 4000 characters; every value below is far under.
 *
 * Machine-drafted, like the rest of the store copy: not a native review pass.
 *
 * Run from the repo root: node scripts/localization/translations/_notes-1.2.1.mjs
 */

import { readFileSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const LISTINGS = join(ROOT, 'docs', 'appstore', 'listings.json');
const LIMIT = 4000;

const NOTES = {
  en: "Much faster with large photo libraries. TidyByte now remembers what it has measured, so after the first scan, Storage and Cleanup open in about a second, even with tens of thousands of photos and videos. They no longer get stuck loading when iCloud or an album changes. A photo you swipe past stops downloading from iCloud at once, and the exact duplicate scan reads far fewer files. Everything still runs on your device: no account, no ads, no subscription.",
  hi: "बड़ी फ़ोटो लाइब्रेरी के साथ अब काफ़ी तेज़। TidyByte अब याद रखता है कि उसने क्या मापा है, इसलिए पहले स्कैन के बाद स्टोरेज और क्लीनअप लगभग एक सेकंड में खुल जाते हैं, भले ही दसियों हज़ार फ़ोटो और वीडियो हों। iCloud या किसी एल्बम में बदलाव होने पर ये अब लोड होते हुए अटकते नहीं। जिस फ़ोटो को आप स्वाइप करके आगे बढ़ जाते हैं, उसकी iCloud से डाउनलोडिंग तुरंत रुक जाती है, और हूबहू डुप्लिकेट का स्कैन अब बहुत कम फ़ाइलें पढ़ता है। सब कुछ अब भी आपके डिवाइस पर ही चलता है: कोई अकाउंट नहीं, कोई विज्ञापन नहीं, कोई सब्सक्रिप्शन नहीं।",
  bn: "বড় ফটো লাইব্রেরিতে এখন অনেক দ্রুত। TidyByte এখন যা মেপেছে তা মনে রাখে, তাই প্রথম স্ক্যানের পর স্টোরেজ আর পরিষ্কার প্রায় এক সেকেন্ডে খোলে, হাজার হাজার ছবি ও ভিডিও থাকলেও। iCloud বা কোনো অ্যালবাম বদলালে এগুলো আর লোড হতে গিয়ে আটকে থাকে না। যে ছবি সোয়াইপ করে পার হয়ে যান, সেটির iCloud থেকে ডাউনলোড সঙ্গে সঙ্গে থেমে যায়, আর হুবহু ডুপ্লিকেট স্ক্যান এখন অনেক কম ফাইল পড়ে। সবকিছু আগের মতোই আপনার ডিভাইসেই চলে: কোনো অ্যাকাউন্ট নেই, বিজ্ঞাপন নেই, সাবস্ক্রিপশন নেই।",
  ta: "பெரிய புகைப்பட நூலகங்களில் இப்போது மிக வேகமாக இயங்குகிறது. TidyByte ஏற்கெனவே அளந்ததை இப்போது நினைவில் வைத்துக்கொள்கிறது, எனவே முதல் ஸ்கேனுக்குப் பிறகு, பல்லாயிரக்கணக்கான புகைப்படங்களும் வீடியோக்களும் இருந்தாலும், சேமிப்பகம் மற்றும் சுத்தம் சுமார் ஒரு வினாடியில் திறக்கின்றன. iCloud அல்லது ஒரு ஆல்பம் மாறும்போது அவை இனி ஏற்றுவதில் சிக்கிக்கொள்வதில்லை. நீங்கள் ஸ்வைப் செய்து கடந்த புகைப்படம் iCloud-இலிருந்து பதிவிறக்குவதை உடனே நிறுத்துகிறது, மேலும் துல்லியமான நகல் ஸ்கேன் மிகக் குறைவான கோப்புகளையே படிக்கிறது. எல்லாமே இன்னும் உங்கள் சாதனத்திலேயே இயங்குகிறது: கணக்கு இல்லை, விளம்பரம் இல்லை, சந்தா இல்லை.",
  te: "పెద్ద ఫోటో లైబ్రరీలతో ఇప్పుడు చాలా వేగంగా పనిచేస్తుంది. TidyByte ఇప్పటికే కొలిచిన వాటిని ఇప్పుడు గుర్తుంచుకుంటుంది, కాబట్టి మొదటి స్కాన్ తర్వాత, పదివేల కొద్దీ ఫోటోలు, వీడియోలు ఉన్నా, నిల్వ మరియు క్లీన్అప్ దాదాపు ఒక సెకనులో తెరుచుకుంటాయి. iCloud లేదా ఏదైనా ఆల్బమ్ మారినప్పుడు అవి ఇక లోడింగ్‌లో నిలిచిపోవు. మీరు స్వైప్ చేసి దాటిన ఫోటో iCloud నుండి డౌన్‌లోడ్ కావడం వెంటనే ఆగిపోతుంది, ఖచ్చితమైన నకిలీల స్కాన్ ఇప్పుడు చాలా తక్కువ ఫైళ్లను చదువుతుంది. అన్నీ ఇప్పటికీ మీ పరికరంలోనే నడుస్తాయి: ఖాతా లేదు, ప్రకటనలు లేవు, సబ్‌స్క్రిప్షన్ లేదు.",
  mr: "मोठ्या फोटो लायब्ररीसह आता खूपच वेगवान. TidyByte आता आधी मोजलेली माहिती लक्षात ठेवते, त्यामुळे पहिल्या स्कॅननंतर, हजारो फोटो आणि व्हिडिओ असले तरी स्टोरेज आणि क्लीनअप सुमारे एका सेकंदात उघडतात. iCloud किंवा एखादा अल्बम बदलल्यावर ते आता लोड होताना अडकत नाहीत. तुम्ही स्वाइप करून पुढे गेलेल्या फोटोचे iCloud वरून डाउनलोड लगेच थांबते, आणि अचूक डुप्लिकेट स्कॅन आता खूप कमी फाइल्स वाचतो. सगळे काही अजूनही तुमच्या डिव्हाइसवरच चालते: खाते नाही, जाहिराती नाहीत, सबस्क्रिप्शन नाही.",
  gu: "મોટી ફોટો લાઇબ્રેરી સાથે હવે ઘણું ઝડપી. TidyByte હવે જે માપ્યું છે તે યાદ રાખે છે, તેથી પહેલા સ્કેન પછી, હજારો ફોટા અને વીડિયો હોય તો પણ સ્ટોરેજ અને ક્લીનઅપ લગભગ એક સેકન્ડમાં ખૂલે છે. iCloud અથવા કોઈ આલ્બમ બદલાય ત્યારે તે હવે લોડ થતાં અટકી જતા નથી. તમે સ્વાઇપ કરીને આગળ વધો તે ફોટાનું iCloudમાંથી ડાઉનલોડ તરત બંધ થઈ જાય છે, અને ચોક્કસ ડુપ્લિકેટ સ્કેન હવે ઘણી ઓછી ફાઇલો વાંચે છે. બધું હજુ પણ તમારા ડિવાઇસ પર જ ચાલે છે: કોઈ એકાઉન્ટ નહીં, કોઈ જાહેરાત નહીં, કોઈ સબ્સ્ક્રિપ્શન નહીં.",
  kn: "ದೊಡ್ಡ ಫೋಟೋ ಲೈಬ್ರರಿಗಳಲ್ಲಿ ಈಗ ಹೆಚ್ಚು ವೇಗ. TidyByte ಈಗ ಈಗಾಗಲೇ ಅಳೆದದ್ದನ್ನು ನೆನಪಿಟ್ಟುಕೊಳ್ಳುತ್ತದೆ, ಹಾಗಾಗಿ ಮೊದಲ ಸ್ಕ್ಯಾನ್ ನಂತರ, ಹತ್ತಾರು ಸಾವಿರ ಫೋಟೋ ಮತ್ತು ವೀಡಿಯೊಗಳಿದ್ದರೂ ಸಂಗ್ರಹಣೆ ಮತ್ತು ಕ್ಲೀನ್ಅಪ್ ಸುಮಾರು ಒಂದು ಸೆಕೆಂಡಿನಲ್ಲಿ ತೆರೆಯುತ್ತವೆ. iCloud ಅಥವಾ ಯಾವುದೇ ಆಲ್ಬಮ್ ಬದಲಾದಾಗ ಅವು ಇನ್ನು ಲೋಡ್ ಆಗುವಲ್ಲಿ ಸಿಲುಕುವುದಿಲ್ಲ. ನೀವು ಸ್ವೈಪ್ ಮಾಡಿ ದಾಟಿದ ಫೋಟೋ iCloud ನಿಂದ ಡೌನ್‌ಲೋಡ್ ಆಗುವುದು ತಕ್ಷಣ ನಿಲ್ಲುತ್ತದೆ, ಮತ್ತು ನಿಖರ ನಕಲಿಗಳ ಸ್ಕ್ಯಾನ್ ಈಗ ತುಂಬಾ ಕಡಿಮೆ ಫೈಲ್‌ಗಳನ್ನು ಓದುತ್ತದೆ. ಎಲ್ಲವೂ ಈಗಲೂ ನಿಮ್ಮ ಸಾಧನದಲ್ಲೇ ನಡೆಯುತ್ತದೆ: ಖಾತೆ ಇಲ್ಲ, ಜಾಹೀರಾತು ಇಲ್ಲ, ಚಂದಾದಾರಿಕೆ ಇಲ್ಲ.",
  ml: "വലിയ ഫോട്ടോ ലൈബ്രറികളിൽ ഇപ്പോൾ വളരെ വേഗം. TidyByte ഇതിനകം അളന്നത് ഇപ്പോൾ ഓർത്തുവയ്ക്കുന്നു, അതിനാൽ ആദ്യ സ്കാനിന് ശേഷം, പതിനായിരക്കണക്കിന് ഫോട്ടോകളും വീഡിയോകളും ഉണ്ടെങ്കിലും സ്റ്റോറേജും ക്ലീനപ്പും ഏകദേശം ഒരു സെക്കൻഡിൽ തുറക്കും. iCloud-ലോ ഒരു ആൽബത്തിലോ മാറ്റം വരുമ്പോൾ അവ ഇനി ലോഡിങ്ങിൽ കുടുങ്ങില്ല. നിങ്ങൾ സ്വൈപ്പ് ചെയ്ത് കടന്നുപോകുന്ന ഫോട്ടോ iCloud-ൽ നിന്ന് ഡൗൺലോഡ് ചെയ്യുന്നത് ഉടൻ നിർത്തുന്നു, കൃത്യമായ ഡ്യൂപ്ലിക്കേറ്റ് സ്കാൻ ഇപ്പോൾ വളരെ കുറച്ച് ഫയലുകൾ മാത്രമേ വായിക്കൂ. എല്ലാം ഇപ്പോഴും നിങ്ങളുടെ ഉപകരണത്തിൽ തന്നെ പ്രവർത്തിക്കുന്നു: അക്കൗണ്ടില്ല, പരസ്യങ്ങളില്ല, സബ്സ്ക്രിപ്ഷനില്ല.",
  pa: "ਵੱਡੀਆਂ ਫ਼ੋਟੋ ਲਾਇਬ੍ਰੇਰੀਆਂ ਨਾਲ ਹੁਣ ਕਿਤੇ ਤੇਜ਼। TidyByte ਹੁਣ ਯਾਦ ਰੱਖਦਾ ਹੈ ਕਿ ਉਸ ਨੇ ਕੀ ਮਾਪਿਆ ਹੈ, ਇਸ ਲਈ ਪਹਿਲੇ ਸਕੈਨ ਤੋਂ ਬਾਅਦ, ਹਜ਼ਾਰਾਂ ਫ਼ੋਟੋਆਂ ਅਤੇ ਵੀਡੀਓ ਹੋਣ 'ਤੇ ਵੀ ਸਟੋਰੇਜ ਅਤੇ ਸਫ਼ਾਈ ਲਗਭਗ ਇੱਕ ਸਕਿੰਟ ਵਿੱਚ ਖੁੱਲ੍ਹ ਜਾਂਦੇ ਹਨ। iCloud ਜਾਂ ਕਿਸੇ ਐਲਬਮ ਵਿੱਚ ਬਦਲਾਅ ਹੋਣ 'ਤੇ ਇਹ ਹੁਣ ਲੋਡ ਹੁੰਦੇ ਹੋਏ ਅਟਕਦੇ ਨਹੀਂ। ਜਿਸ ਫ਼ੋਟੋ ਨੂੰ ਤੁਸੀਂ ਸਵਾਈਪ ਕਰਕੇ ਅੱਗੇ ਲੰਘ ਜਾਂਦੇ ਹੋ, ਉਸ ਦੀ iCloud ਤੋਂ ਡਾਊਨਲੋਡਿੰਗ ਤੁਰੰਤ ਰੁਕ ਜਾਂਦੀ ਹੈ, ਅਤੇ ਹੂ-ਬ-ਹੂ ਡੁਪਲੀਕੇਟ ਸਕੈਨ ਹੁਣ ਬਹੁਤ ਘੱਟ ਫ਼ਾਈਲਾਂ ਪੜ੍ਹਦਾ ਹੈ। ਸਭ ਕੁਝ ਅਜੇ ਵੀ ਤੁਹਾਡੇ ਡਿਵਾਈਸ 'ਤੇ ਹੀ ਚੱਲਦਾ ਹੈ: ਕੋਈ ਖਾਤਾ ਨਹੀਂ, ਕੋਈ ਇਸ਼ਤਿਹਾਰ ਨਹੀਂ, ਕੋਈ ਸਬਸਕ੍ਰਿਪਸ਼ਨ ਨਹੀਂ।",
  es: "Mucho más rápida con bibliotecas de fotos grandes. TidyByte ahora recuerda lo que ya ha medido, así que, tras el primer análisis, Almacenamiento y Limpieza se abren en un segundo aproximadamente, incluso con decenas de miles de fotos y vídeos. Ya no se quedan cargando cuando cambia iCloud o un álbum. Una foto que dejas atrás al deslizar deja de descargarse de iCloud al instante, y el análisis de duplicados exactos lee muchos menos archivos. Todo sigue funcionando en tu dispositivo: sin cuenta, sin anuncios, sin suscripción.",
  fr: "Beaucoup plus rapide avec les grandes photothèques. TidyByte retient désormais ce qu'il a déjà mesuré : après la première analyse, Stockage et Nettoyage s'ouvrent en une seconde environ, même avec des dizaines de milliers de photos et de vidéos. Ils ne restent plus bloqués en chargement quand iCloud ou un album change. Une photo que vous passez d'un glissement arrête aussitôt de se télécharger depuis iCloud, et l'analyse des doublons exacts lit beaucoup moins de fichiers. Tout fonctionne toujours sur votre appareil : sans compte, sans publicité, sans abonnement.",
  de: "Viel schneller bei großen Fotomediatheken. TidyByte merkt sich jetzt, was es bereits gemessen hat. Nach dem ersten Scan öffnen sich Speicher und Bereinigung in etwa einer Sekunde, auch bei Zehntausenden Fotos und Videos. Sie bleiben nicht mehr beim Laden hängen, wenn sich iCloud oder ein Album ändert. Ein Foto, an dem du vorbeiwischst, wird sofort nicht mehr aus iCloud geladen, und die Suche nach exakten Duplikaten liest viel weniger Dateien. Alles läuft weiterhin auf deinem Gerät: kein Konto, keine Werbung, kein Abo.",
  "pt-BR": "Muito mais rápido com bibliotecas de fotos grandes. O TidyByte agora lembra o que já mediu, então, depois da primeira análise, Armazenamento e Limpeza abrem em cerca de um segundo, mesmo com dezenas de milhares de fotos e vídeos. Eles não ficam mais travados carregando quando o iCloud ou um álbum muda. Uma foto que você passa com o dedo para de baixar do iCloud na hora, e a busca por duplicatas exatas lê muito menos arquivos. Tudo continua rodando no seu aparelho: sem conta, sem anúncios, sem assinatura.",
  it: "Molto più veloce con le librerie di foto grandi. TidyByte ora ricorda ciò che ha già misurato: dopo la prima scansione, Archiviazione e Pulizia si aprono in circa un secondo, anche con decine di migliaia di foto e video. Non restano più bloccate in caricamento quando cambia iCloud o un album. Una foto che superi con uno scorrimento smette subito di scaricarsi da iCloud, e la scansione dei duplicati esatti legge molti meno file. Tutto funziona ancora sul tuo dispositivo: nessun account, nessuna pubblicità, nessun abbonamento.",
  ja: "大きな写真ライブラリでも大幅に高速になりました。TidyByte は一度計測した内容を記憶するようになったため、最初のスキャン後は、写真やビデオが数万件あってもストレージとクリーンアップが約1秒で開きます。iCloud やアルバムに変更があっても、読み込み中のまま止まることはなくなりました。スワイプで通り過ぎた写真は iCloud からのダウンロードをすぐに停止し、完全一致の重複スキャンで読み込むファイルも大幅に減りました。これまでどおり、すべてデバイス上で動作します。アカウント不要、広告なし、サブスクリプションなし。",
  ko: "대용량 사진 보관함에서 훨씬 빨라졌습니다. 이제 TidyByte가 이미 측정한 내용을 기억하므로, 첫 스캔 이후에는 사진과 동영상이 수만 개여도 저장 공간과 정리가 약 1초 만에 열립니다. iCloud나 앨범이 바뀌어도 더 이상 로딩 중에 멈추지 않습니다. 스와이프로 넘긴 사진은 iCloud 다운로드를 바로 멈추고, 정확히 일치하는 중복 항목 스캔이 읽는 파일 수도 크게 줄었습니다. 모든 작업은 여전히 기기에서만 실행됩니다. 계정, 광고, 구독이 없습니다.",
  "zh-Hans": "大型照片图库现在快得多。TidyByte 会记住已经测量过的内容，因此首次扫描之后，即使有数万张照片和视频，存储空间和清理也只需约一秒即可打开。iCloud 或相簿发生变化时，它们不会再卡在加载中。滑过的照片会立即停止从 iCloud 下载，完全重复项扫描读取的文件也大幅减少。一切仍在你的设备上运行：无需账户，没有广告，没有订阅。",
  ru: "Намного быстрее на больших медиатеках. Теперь TidyByte запоминает то, что уже измерил, поэтому после первого сканирования Хранилище и Очистка открываются примерно за секунду, даже если у вас десятки тысяч фото и видео. Они больше не зависают на загрузке, когда меняется iCloud или альбом. Фото, которое вы пролистали, сразу перестаёт загружаться из iCloud, а поиск точных дубликатов читает гораздо меньше файлов. Всё по-прежнему работает на вашем устройстве: без аккаунта, без рекламы, без подписки.",
  ar: "أسرع بكثير مع مكتبات الصور الكبيرة. يتذكر TidyByte الآن ما قاسه من قبل، لذلك بعد الفحص الأول يُفتح التخزين والتنظيف في ثانية تقريبًا، حتى مع عشرات الآلاف من الصور والفيديوهات. لم يعودا يتوقفان أثناء التحميل عندما يتغير iCloud أو أحد الألبومات. الصورة التي تتجاوزها بالسحب تتوقف عن التنزيل من iCloud فورًا، ويقرأ فحص المكررات المتطابقة تمامًا ملفات أقل بكثير. كل شيء ما زال يعمل على جهازك: بلا حساب، بلا إعلانات، بلا اشتراك.",
  he: "מהיר הרבה יותר בספריות תמונות גדולות. TidyByte זוכר עכשיו מה כבר מדד, כך שאחרי הסריקה הראשונה אחסון וניקוי נפתחים בתוך כשנייה, גם עם עשרות אלפי תמונות וסרטונים. הם כבר לא נתקעים בטעינה כש-iCloud או אלבום משתנים. תמונה שעוברים עליה בהחלקה מפסיקה מיד לרדת מ-iCloud, וסריקת הכפולים הזהים קוראת הרבה פחות קבצים. הכול עדיין רץ במכשיר שלך: בלי חשבון, בלי פרסומות, בלי מנוי.",
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
