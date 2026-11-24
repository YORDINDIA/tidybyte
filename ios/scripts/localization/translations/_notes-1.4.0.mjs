#!/usr/bin/env node
/**
 * Release notes for 1.4.0, in all 21 storefront locales.
 *
 * 1.4.0 keeps long jobs going when the user leaves the app (background on
 * iOS 26, resume on return before), saves swipe sessions and the Cleanup
 * tools' scans and picks, moves Undo under the photo, and adds Reduce Swipe
 * Motion.
 *
 * The notes name no swipe direction: right and left swap in Arabic and Hebrew.
 * Tool, tab and deck names are the app's own translations from
 * Localizable.xcstrings. The closing sentence is the 1.3.0 one in every
 * language. "TidyByte", "iOS" and "Live Photos" stay Latin.
 *
 * App Store Connect allows 4000 characters; every value below is far under.
 *
 * Machine-drafted, like the rest of the store copy: not a native review pass.
 *
 * Run from ios/: node scripts/localization/translations/_notes-1.4.0.mjs
 */

import { readFileSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const LISTINGS = join(ROOT, 'docs', 'appstore', 'listings.json');
const LIMIT = 4000;

const NOTES = {
  en: "Long jobs now survive leaving the app: Live Photo conversion and video and photo compression keep running in the background on iOS 26, and on earlier versions they continue when you come back. Swipe sessions remember your place and your marked photos until you reset them in Settings, and the Cleanup tools keep their last scan and your picks. Undo now sits under the photo, and the new Reduce Swipe Motion setting keeps the cards calm. Everything still runs on your device: no account, no ads, no subscription.",
  hi: "लंबे काम अब ऐप से बाहर जाने पर भी नहीं रुकते: Live Photo कन्वर्ज़न और वीडियो व फ़ोटो कंप्रेशन iOS 26 पर बैकग्राउंड में चलते रहते हैं, और पुराने वर्ज़न पर आपके लौटने पर आगे बढ़ते हैं। स्वाइप सेशन आपकी जगह और चिह्नित फ़ोटो याद रखता है, जब तक आप सेटिंग्स में उसे रीसेट न करें, और क्लीनअप टूल अपना पिछला स्कैन और आपकी चुनी हुई चीज़ें रखते हैं। पूर्ववत करें अब फ़ोटो के नीचे है, और नई स्वाइप मोशन कम करें सेटिंग कार्ड को शांत रखती है। सब कुछ अब भी आपके डिवाइस पर ही चलता है: कोई अकाउंट नहीं, कोई विज्ञापन नहीं, कोई सब्सक्रिप्शन नहीं।",
  bn: "লম্বা কাজ এখন অ্যাপ থেকে বেরিয়ে গেলেও থামে না: Live Photo রূপান্তর আর ভিডিও ও ফটো কমপ্রেশন iOS 26-এ ব্যাকগ্রাউন্ডে চলতে থাকে, আর আগের সংস্করণে আপনি ফিরলে আবার এগোয়। সোয়াইপ সেশন আপনার জায়গা আর চিহ্নিত ফটো মনে রাখে, যতক্ষণ না আপনি সেটিংসে রিসেট করেন, আর পরিষ্কার টুলগুলো শেষ স্ক্যান ও আপনার বাছাই রেখে দেয়। আনডু করুন এখন ফটোর নিচে, আর নতুন সোয়াইপের নড়াচড়া কমান সেটিং কার্ডগুলোকে শান্ত রাখে। সবকিছু আগের মতোই আপনার ডিভাইসেই চলে: কোনো অ্যাকাউন্ট নেই, বিজ্ঞাপন নেই, সাবস্ক্রিপশন নেই।",
  ta: "நீண்ட வேலைகள் இப்போது ஆப்பை விட்டு வெளியேறினாலும் நிற்காது: Live Photo மாற்றமும் வீடியோ, புகைப்படச் சுருக்கமும் iOS 26-இல் பின்னணியில் தொடர்ந்து இயங்கும்; முந்தைய பதிப்புகளில் நீங்கள் திரும்பியதும் தொடரும். ஸ்வைப் அமர்வு உங்கள் இடத்தையும் குறித்த புகைப்படங்களையும் அமைப்புகளில் மீட்டமைக்கும் வரை நினைவில் வைக்கும்; சுத்தம் கருவிகள் கடைசி ஸ்கேனையும் உங்கள் தேர்வுகளையும் வைத்திருக்கும். மீளச் செய் இப்போது புகைப்படத்தின் கீழே உள்ளது, புதிய ஸ்வைப் இயக்கத்தைக் குறை அமைப்பு அட்டைகளை அமைதியாக வைக்கிறது. எல்லாமே இன்னும் உங்கள் சாதனத்திலேயே இயங்குகிறது: கணக்கு இல்லை, விளம்பரம் இல்லை, சந்தா இல்லை.",
  te: "పొడవైన పనులు ఇప్పుడు యాప్ నుండి బయటికి వెళ్లినా ఆగవు: Live Photo మార్పిడి, వీడియో మరియు ఫోటో కుదింపు iOS 26లో బ్యాక్‌గ్రౌండ్‌లో కొనసాగుతాయి, పాత వెర్షన్లలో మీరు తిరిగి వచ్చినప్పుడు కొనసాగుతాయి. స్వైప్ సెషన్ మీ స్థానాన్ని, గుర్తు పెట్టిన ఫోటోలను సెట్టింగ్‌లలో రీసెట్ చేసే వరకు గుర్తుంచుకుంటుంది, క్లీన్అప్ సాధనాలు చివరి స్కాన్‌ను, మీ ఎంపికలను ఉంచుకుంటాయి. అన్డూ ఇప్పుడు ఫోటో కింద ఉంది, కొత్త స్వైప్ కదలికను తగ్గించు సెట్టింగ్ కార్డులను ప్రశాంతంగా ఉంచుతుంది. అన్నీ ఇప్పటికీ మీ పరికరంలోనే నడుస్తాయి: ఖాతా లేదు, ప్రకటనలు లేవు, సబ్‌స్క్రిప్షన్ లేదు.",
  mr: "मोठी कामे आता ॲपमधून बाहेर गेल्यावरही थांबत नाहीत: Live Photo रूपांतरण आणि व्हिडिओ व फोटो कंप्रेशन iOS 26 वर बॅकग्राउंडमध्ये चालू राहतात, आणि जुन्या आवृत्त्यांवर तुम्ही परतल्यावर पुढे सुरू होतात. स्वाइप सत्र तुमची जागा आणि चिन्हांकित फोटो सेटिंग्जमध्ये रीसेट करेपर्यंत लक्षात ठेवते, आणि क्लीनअप साधने शेवटचे स्कॅन आणि तुमच्या निवडी जपून ठेवतात. पूर्वपदावर आणा आता फोटोच्या खाली आहे, आणि नवीन स्वाइप हालचाल कमी करा सेटिंग कार्ड शांत ठेवते. सगळे काही अजूनही तुमच्या डिव्हाइसवरच चालते: खाते नाही, जाहिराती नाहीत, सबस्क्रिप्शन नाही.",
  gu: "લાંબા કામ હવે ઍપમાંથી બહાર જવા પર પણ અટકતા નથી: Live Photo કન્વર્ઝન અને વિડિયો તથા ફોટો કોમ્પ્રેશન iOS 26 પર બૅકગ્રાઉન્ડમાં ચાલુ રહે છે, અને જૂના વર્ઝન પર તમે પાછા આવો ત્યારે આગળ વધે છે. સ્વાઇપ સત્ર તમારી જગ્યા અને માર્ક કરેલા ફોટા સેટિંગ્સમાં રીસેટ ન કરો ત્યાં સુધી યાદ રાખે છે, અને ક્લીનઅપ ટૂલ્સ છેલ્લું સ્કેન અને તમારી પસંદગી રાખે છે. પૂર્વવત્ કરો હવે ફોટાની નીચે છે, અને નવું સ્વાઇપ ગતિ ઘટાડો સેટિંગ કાર્ડને શાંત રાખે છે. બધું હજુ પણ તમારા ડિવાઇસ પર જ ચાલે છે: કોઈ એકાઉન્ટ નહીં, કોઈ જાહેરાત નહીં, કોઈ સબ્સ્ક્રિપ્શન નહીં.",
  kn: "ದೀರ್ಘ ಕೆಲಸಗಳು ಈಗ ಆ್ಯಪ್‌ನಿಂದ ಹೊರಹೋದರೂ ನಿಲ್ಲುವುದಿಲ್ಲ: Live Photo ಪರಿವರ್ತನೆ ಮತ್ತು ವೀಡಿಯೊ ಹಾಗೂ ಫೋಟೋ ಸಂಕೋಚನ iOS 26 ನಲ್ಲಿ ಹಿನ್ನೆಲೆಯಲ್ಲಿ ಮುಂದುವರಿಯುತ್ತವೆ, ಹಳೆಯ ಆವೃತ್ತಿಗಳಲ್ಲಿ ನೀವು ಹಿಂತಿರುಗಿದಾಗ ಮುಂದುವರಿಯುತ್ತವೆ. ಸ್ವೈಪ್ ಸೆಷನ್ ನಿಮ್ಮ ಸ್ಥಾನ ಮತ್ತು ಗುರುತಿಸಿದ ಫೋಟೋಗಳನ್ನು ಸೆಟ್ಟಿಂಗ್‌ಗಳಲ್ಲಿ ಮರುಹೊಂದಿಸುವವರೆಗೆ ನೆನಪಿಡುತ್ತದೆ, ಮತ್ತು ಕ್ಲೀನ್ಅಪ್ ಪರಿಕರಗಳು ಕೊನೆಯ ಸ್ಕ್ಯಾನ್ ಮತ್ತು ನೀವು ಆಯ್ಕೆ ಮಾಡಿದ ಐಟಂಗಳನ್ನು ಉಳಿಸಿಕೊಳ್ಳುತ್ತವೆ. ಹಿಂತಿರುಗಿಸಿ ಈಗ ಫೋಟೋದ ಕೆಳಗಿದೆ, ಮತ್ತು ಹೊಸ ಸ್ವೈಪ್ ಚಲನೆ ಕಡಿಮೆ ಮಾಡಿ ಸೆಟ್ಟಿಂಗ್ ಕಾರ್ಡ್‌ಗಳನ್ನು ಶಾಂತವಾಗಿಡುತ್ತದೆ. ಎಲ್ಲವೂ ಈಗಲೂ ನಿಮ್ಮ ಸಾಧನದಲ್ಲೇ ನಡೆಯುತ್ತದೆ: ಖಾತೆ ಇಲ್ಲ, ಜಾಹೀರಾತು ಇಲ್ಲ, ಚಂದಾದಾರಿಕೆ ಇಲ್ಲ.",
  ml: "നീണ്ട ജോലികൾ ഇപ്പോൾ ആപ്പിൽ നിന്ന് പുറത്തുപോയാലും നിൽക്കില്ല: Live Photo കൺവേർഷനും വീഡിയോ, ഫോട്ടോ കംപ്രഷനും iOS 26-ൽ ബാക്ക്ഗ്രൗണ്ടിൽ തുടരും, പഴയ പതിപ്പുകളിൽ നിങ്ങൾ തിരിച്ചെത്തുമ്പോൾ തുടരും. സ്വൈപ്പ് സെഷൻ നിങ്ങളുടെ സ്ഥാനവും അടയാളപ്പെടുത്തിയ ഫോട്ടോകളും സെറ്റിംഗ്സിൽ റീസെറ്റ് ചെയ്യുന്നതുവരെ ഓർക്കും, ക്ലീനപ്പ് ടൂളുകൾ അവസാന സ്കാനും നിങ്ങളുടെ തിരഞ്ഞെടുപ്പുകളും സൂക്ഷിക്കും. പഴയപടിയാക്കുക ഇപ്പോൾ ഫോട്ടോയ്ക്ക് താഴെയാണ്, പുതിയ സ്വൈപ്പ് ചലനം കുറയ്ക്കുക സെറ്റിംഗ് കാർഡുകളെ ശാന്തമാക്കുന്നു. എല്ലാം ഇപ്പോഴും നിങ്ങളുടെ ഉപകരണത്തിൽ തന്നെ പ്രവർത്തിക്കുന്നു: അക്കൗണ്ടില്ല, പരസ്യങ്ങളില്ല, സബ്സ്ക്രിപ്ഷനില്ല.",
  pa: "ਲੰਬੇ ਕੰਮ ਹੁਣ ਐਪ ਤੋਂ ਬਾਹਰ ਜਾਣ 'ਤੇ ਵੀ ਨਹੀਂ ਰੁਕਦੇ: Live Photo ਕਨਵਰਜ਼ਨ ਅਤੇ ਵੀਡੀਓ ਤੇ ਫ਼ੋਟੋ ਕੰਪਰੈਸ਼ਨ iOS 26 'ਤੇ ਬੈਕਗ੍ਰਾਊਂਡ ਵਿੱਚ ਚੱਲਦੇ ਰਹਿੰਦੇ ਹਨ, ਅਤੇ ਪੁਰਾਣੇ ਵਰਜ਼ਨਾਂ 'ਤੇ ਤੁਹਾਡੇ ਵਾਪਸ ਆਉਣ 'ਤੇ ਅੱਗੇ ਚੱਲਦੇ ਹਨ। ਸਵਾਈਪ ਸੈਸ਼ਨ ਤੁਹਾਡੀ ਥਾਂ ਅਤੇ ਨਿਸ਼ਾਨਬੱਧ ਫ਼ੋਟੋਆਂ ਸੈਟਿੰਗਾਂ ਵਿੱਚ ਰੀਸੈੱਟ ਕਰਨ ਤੱਕ ਯਾਦ ਰੱਖਦਾ ਹੈ, ਅਤੇ ਸਫ਼ਾਈ ਟੂਲ ਆਖਰੀ ਸਕੈਨ ਅਤੇ ਤੁਹਾਡੀਆਂ ਚੋਣਾਂ ਸੰਭਾਲ ਕੇ ਰੱਖਦੇ ਹਨ। ਵਾਪਸ ਲਓ ਹੁਣ ਫ਼ੋਟੋ ਦੇ ਹੇਠਾਂ ਹੈ, ਅਤੇ ਨਵੀਂ ਸਵਾਈਪ ਹਿਲਜੁਲ ਘਟਾਓ ਸੈਟਿੰਗ ਕਾਰਡਾਂ ਨੂੰ ਸ਼ਾਂਤ ਰੱਖਦੀ ਹੈ। ਸਭ ਕੁਝ ਅਜੇ ਵੀ ਤੁਹਾਡੇ ਡਿਵਾਈਸ 'ਤੇ ਹੀ ਚੱਲਦਾ ਹੈ: ਕੋਈ ਖਾਤਾ ਨਹੀਂ, ਕੋਈ ਇਸ਼ਤਿਹਾਰ ਨਹੀਂ, ਕੋਈ ਸਬਸਕ੍ਰਿਪਸ਼ਨ ਨਹੀਂ।",
  es: "Las tareas largas ya no se detienen al salir de la app: la conversión de Live Photos y la compresión de vídeos y fotos siguen en segundo plano en iOS 26, y en versiones anteriores continúan cuando vuelves. Las sesiones de deslizamiento recuerdan dónde te quedaste y las fotos que marcaste hasta que las restableces en Ajustes, y las herramientas de Limpieza conservan su último análisis y tus selecciones. Deshacer está ahora bajo la foto, y el nuevo ajuste Reducir movimiento al deslizar mantiene las tarjetas tranquilas. Todo sigue funcionando en tu dispositivo: sin cuenta, sin anuncios, sin suscripción.",
  fr: "Les longues tâches ne s’arrêtent plus quand vous quittez l’app : la conversion des Live Photos et la compression des vidéos et des photos continuent en arrière-plan sous iOS 26, et reprennent à votre retour sur les versions antérieures. Les sessions de balayage retiennent où vous en êtes et les photos marquées jusqu’à ce que vous les réinitialisiez dans Réglages, et les outils de Nettoyage gardent leur dernière analyse et vos choix. Annuler est désormais sous la photo, et le nouveau réglage Réduire le mouvement du balayage garde les cartes calmes. Tout fonctionne toujours sur votre appareil : sans compte, sans publicité, sans abonnement.",
  de: "Lange Aufgaben laufen jetzt weiter, wenn du die App verlässt: Live Photo-Konvertierung und Video- und Fotokomprimierung laufen unter iOS 26 im Hintergrund weiter und setzen unter älteren Versionen fort, sobald du zurückkommst. Wischsitzungen merken sich deine Position und markierte Fotos, bis du sie in den Einstellungen zurücksetzt, und die Bereinigungswerkzeuge behalten ihren letzten Scan und deine Auswahl. Rückgängig liegt jetzt unter dem Foto, und die neue Einstellung Wischbewegung reduzieren hält die Karten ruhig. Alles läuft weiterhin auf deinem Gerät: kein Konto, keine Werbung, kein Abo.",
  "pt-BR": "Tarefas longas não param mais ao sair do app: a conversão de Live Photos e a compressão de vídeos e fotos continuam em segundo plano no iOS 26 e, em versões anteriores, seguem quando você volta. As sessões de deslizes lembram onde você parou e as fotos marcadas até você redefini-las em Ajustes, e as ferramentas de Limpeza guardam a última análise e suas escolhas. Desfazer agora fica abaixo da foto, e o novo ajuste Reduzir movimento ao deslizar deixa os cartões mais calmos. Tudo continua rodando no seu aparelho: sem conta, sem anúncios, sem assinatura.",
  it: "Le attività lunghe non si fermano più quando lasci l’app: la conversione delle Live Photo e la compressione di video e foto continuano in background su iOS 26 e, nelle versioni precedenti, riprendono quando torni. Le sessioni di scorrimento ricordano dove eri e le foto segnate finché non le reimposti in Impostazioni, e gli strumenti di Pulizia conservano l’ultima analisi e le tue scelte. Annulla ora è sotto la foto, e la nuova opzione Riduci movimento scorrimento tiene calme le schede. Tutto funziona ancora sul tuo dispositivo: nessun account, nessuna pubblicità, nessun abbonamento.",
  ja: "長い処理はアプリを離れても止まらなくなりました。Live Photoの変換とビデオ・写真の圧縮は、iOS 26ではバックグラウンドで続き、それ以前のバージョンでは戻ったときに再開します。スワイプセッションは、設定でリセットするまで現在の位置とマークした写真を覚えています。クリーンアップの各ツールは前回のスキャンと選択を保持します。「取り消す」は写真の下に移り、新しい「スワイプの動きを減らす」設定でカードの動きを抑えられます。これまでどおり、すべてデバイス上で動作します。アカウント不要、広告なし、サブスクリプションなし。",
  ko: "긴 작업이 이제 앱을 떠나도 멈추지 않습니다. Live Photo 변환과 동영상·사진 압축은 iOS 26에서 백그라운드로 계속되고, 이전 버전에서는 돌아오면 이어서 진행됩니다. 스와이프 세션은 설정에서 재설정할 때까지 위치와 표시한 사진을 기억하고, 정리 도구는 마지막 스캔과 선택한 항목을 유지합니다. 실행 취소는 이제 사진 아래에 있고, 새로운 스와이프 동작 줄이기 설정으로 카드 움직임을 줄일 수 있습니다. 모든 작업은 여전히 기기에서만 실행됩니다. 계정, 광고, 구독이 없습니다.",
  "zh-Hans": "离开应用后，耗时任务也不会再中断：在 iOS 26 上，Live Photo 转换以及视频和照片压缩会在后台继续运行；在更早的版本上，回到应用时会接着进行。滑动会话会记住你的位置和已标记的照片，直到你在“设置”中重置；清理工具会保留上次扫描和你的选择。撤销现在位于照片下方，新的“减少滑动动画”设置让卡片更安静。一切仍在你的设备上运行：无需账户，没有广告，没有订阅。",
  ru: "Долгие задачи больше не останавливаются, когда вы выходите из приложения: преобразование Live Photos и сжатие видео и фото продолжаются в фоне на iOS 26, а на более ранних версиях возобновляются, когда вы возвращаетесь. Сеансы свайпов помнят, где вы остановились, и отмеченные фото, пока вы не сбросите их в «Настройках», а инструменты очистки хранят последнее сканирование и ваш выбор. «Отменить» теперь под фото, а новая настройка «Меньше движения при свайпе» делает карточки спокойнее. Всё по-прежнему работает на вашем устройстве: без аккаунта, без рекламы, без подписки.",
  ar: "لم تعد المهام الطويلة تتوقف عند مغادرة التطبيق: يستمر تحويل Live Photos وضغط الفيديوهات والصور في الخلفية على iOS 26، ويتابع في الإصدارات الأقدم عند عودتك. تتذكر جلسات السحب موضعك والصور المحددة حتى تعيد تعيينها في «الإعدادات»، وتحتفظ أدوات التنظيف بآخر فحص وباختياراتك. أصبح زر تراجع أسفل الصورة، ويجعل الإعداد الجديد تقليل حركة السحب البطاقات أهدأ. كل شيء ما زال يعمل على جهازك: بلا حساب، بلا إعلانات، بلا اشتراك.",
  he: "משימות ארוכות כבר לא נעצרות כשיוצאים מהאפליקציה: המרת Live Photos וכיווץ סרטונים ותמונות ממשיכים ברקע ב-iOS 26, ובגרסאות קודמות ממשיכים כשחוזרים. הפעלות ההחלקה זוכרות איפה עצרת ואת התמונות שסימנת עד שתאפס אותן בהגדרות, וכלי הניקוי שומרים את הסריקה האחרונה ואת הבחירות שלך. בטל נמצא עכשיו מתחת לתמונה, וההגדרה החדשה הפחת תנועת החלקה שומרת על הכרטיסים רגועים. הכול עדיין רץ במכשיר שלך: בלי חשבון, בלי פרסומות, בלי מנוי.",
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
