#!/usr/bin/env node
/**
 * Release notes for 1.2.0, in all 21 storefront locales.
 *
 * 1.2.0 covers the swipe card that shows the whole photo, the more reliable
 * compression with the reason shown under an item that cannot be compressed,
 * the safer delete path (a cancelled iOS delete prompt counts nothing as freed),
 * and cleanup screens that fit large text sizes.
 *
 * The closing sentence is the 1.1.3 one in every language, so the on-device
 * promise reads the same as before. "TidyByte" and "iOS" stay Latin.
 *
 * App Store Connect allows 4000 characters; every value below is far under.
 *
 * Machine-drafted, like the rest of the store copy: not a native review pass.
 *
 * Run from the repo root: node scripts/localization/translations/_notes-1.2.0.mjs
 */

import { readFileSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const LISTINGS = join(ROOT, 'docs', 'appstore', 'listings.json');
const LIMIT = 4000;

const NOTES = {
  en: "Swipe cards now show the whole photo, so wide shots are no longer cropped. Video and photo compression is more reliable, and when an item cannot be compressed, the full reason now shows under it. Deletes are safer: if you cancel the iOS delete prompt, nothing is counted as freed. Cleanup screens now fit large text sizes without cutting off words. Plus many small fixes and better translations. Everything still runs on your device: no account, no ads, no subscription.",
  hi: "स्वाइप कार्ड अब पूरी फ़ोटो दिखाते हैं, इसलिए चौड़ी तस्वीरें अब नहीं कटतीं। वीडियो और फ़ोटो कंप्रेशन अब अधिक भरोसेमंद है, और जब कोई आइटम कंप्रेस नहीं हो पाता, तो उसके नीचे पूरा कारण दिखता है। हटाना अब अधिक सुरक्षित है: अगर आप iOS का हटाने वाला प्रॉम्प्ट रद्द करते हैं, तो कुछ भी खाली हुई जगह में नहीं गिना जाता। क्लीनअप स्क्रीन अब बड़े टेक्स्ट साइज़ में भी फ़िट होती हैं, और शब्द नहीं कटते। साथ में कई छोटे सुधार और बेहतर अनुवाद। सब कुछ अब भी आपके डिवाइस पर ही चलता है: कोई अकाउंट नहीं, कोई विज्ञापन नहीं, कोई सब्सक्रिप्शन नहीं।",
  bn: "এখন সোয়াইপ কার্ডে পুরো ছবিটি দেখা যায়, ফলে চওড়া ছবি আর কাটা পড়ে না। ভিডিও ও ছবি কমপ্রেশন আগের চেয়ে নির্ভরযোগ্য, এবং কোনো আইটেম কমপ্রেস করা না গেলে নিচে পুরো কারণ দেখানো হয়। মোছা আরও নিরাপদ: iOS-এর মোছার প্রম্পট বাতিল করলে কিছুই খালি হওয়া জায়গা হিসেবে গণ্য হয় না। ক্লিনআপ স্ক্রিন এখন বড় টেক্সট সাইজেও ঠিকমতো বসে, শব্দ কাটে না। সঙ্গে আরও অনেক ছোট সংশোধন ও ভালো অনুবাদ। সবকিছু এখনও আপনার ডিভাইসেই চলে: অ্যাকাউন্ট নেই, বিজ্ঞাপন নেই, সাবস্ক্রিপশন নেই।",
  ta: "ஸ்வைப் கார்டுகள் இப்போது முழு புகைப்படத்தையும் காட்டுகின்றன, அதனால் அகலமான படங்கள் இனி வெட்டப்படுவதில்லை. வீடியோ மற்றும் புகைப்பட சுருக்கம் இப்போது மேலும் நம்பகமானது; ஒரு உருப்படியைச் சுருக்க முடியாதபோது, அதன் கீழே முழு காரணம் தோன்றும். நீக்குவது இப்போது பாதுகாப்பானது: iOS நீக்கும் கேட்பை நீங்கள் ரத்து செய்தால், எதுவும் விடுவிக்கப்பட்ட இடமாகக் கணக்கிடப்படாது. சுத்தம் செய்யும் திரைகள் இப்போது பெரிய எழுத்து அளவுகளிலும் சொற்கள் துண்டிக்கப்படாமல் பொருந்துகின்றன. மேலும் பல சிறிய திருத்தங்களும் சிறந்த மொழிபெயர்ப்புகளும். எல்லாமே இன்னும் உங்கள் சாதனத்திலேயே இயங்குகிறது: கணக்கு இல்லை, விளம்பரங்கள் இல்லை, சந்தா இல்லை.",
  te: "స్వైప్ కార్డ్‌లు ఇప్పుడు మొత్తం ఫోటోను చూపుతాయి, కాబట్టి వెడల్పాటి షాట్‌లు ఇక కత్తిరించబడవు. వీడియో మరియు ఫోటో కంప్రెషన్ మరింత నమ్మదగినది; ఒక అంశాన్ని కంప్రెస్ చేయలేకపోతే, దాని కింద పూర్తి కారణం కనిపిస్తుంది. తొలగింపులు మరింత సురక్షితం: iOS తొలగింపు ప్రాంప్ట్‌ను మీరు రద్దు చేస్తే, ఏదీ ఖాళీ అయిన స్థలంగా లెక్కించబడదు. క్లీనప్ స్క్రీన్‌లు ఇప్పుడు పెద్ద టెక్స్ట్ సైజుల్లోనూ పదాలు కత్తిరించకుండా సరిపోతాయి. ఇంకా అనేక చిన్న పరిష్కారాలు మరియు మెరుగైన అనువాదాలు. అంతా ఇప్పటిలాగే మీ పరికరంలోనే నడుస్తుంది: ఖాతా లేదు, ప్రకటనలు లేవు, సబ్‌స్క్రిప్షన్ లేదు.",
  mr: "स्वाइप कार्ड आता संपूर्ण फोटो दाखवतात, त्यामुळे रुंद शॉट्स आता कापले जात नाहीत. व्हिडिओ आणि फोटो कंप्रेशन अधिक विश्वसनीय झाले आहे, आणि एखादी वस्तू कंप्रेस करता आली नाही तर तिच्या खाली पूर्ण कारण दिसते. हटवणे अधिक सुरक्षित झाले आहे: तुम्ही iOS चा हटवण्याचा प्रॉम्प्ट रद्द केला, तर काहीही मोकळी जागा म्हणून मोजले जात नाही. क्लीनअप स्क्रीन आता मोठ्या मजकूर आकारातही शब्द न कापता बसतात. याशिवाय अनेक छोट्या दुरुस्त्या आणि चांगली भाषांतरे. सर्व काही अजूनही तुमच्या डिव्हाइसवरच चालते: खाते नाही, जाहिराती नाहीत, सदस्यता नाही.",
  gu: "સ્વાઇપ કાર્ડ હવે આખો ફોટો બતાવે છે, તેથી પહોળા શોટ્સ હવે કાપાતા નથી. વીડિયો અને ફોટો કોમ્પ્રેશન વધુ ભરોસાપાત્ર છે, અને કોઈ આઇટમ કોમ્પ્રેસ ન થઈ શકે ત્યારે તેની નીચે પૂરું કારણ દેખાય છે. કાઢી નાખવું હવે વધુ સુરક્ષિત છે: જો તમે iOS નો કાઢી નાખવાનો પ્રોમ્પ્ટ રદ કરો, તો કંઈપણ ખાલી થયેલી જગ્યા તરીકે ગણાતું નથી. ક્લીનઅપ સ્ક્રીન હવે મોટા ટેક્સ્ટ સાઇઝમાં પણ શબ્દો કાપ્યા વિના બંધબેસે છે. સાથે ઘણા નાના સુધારા અને વધુ સારા અનુવાદ. બધું હજી પણ તમારા ડિવાઇસ પર ચાલે છે: ખાતું નહીં, જાહેરાત નહીં, સબ્સ્ક્રિપ્શન નહીં.",
  kn: "ಸ್ವೈಪ್ ಕಾರ್ಡ್‌ಗಳು ಈಗ ಇಡೀ ಫೋಟೋವನ್ನು ತೋರಿಸುತ್ತವೆ, ಆದ್ದರಿಂದ ಅಗಲವಾದ ಶಾಟ್‌ಗಳು ಇನ್ನು ಕತ್ತರಿಸಲ್ಪಡುವುದಿಲ್ಲ. ವೀಡಿಯೊ ಮತ್ತು ಫೋಟೋ ಸಂಕುಚನ ಈಗ ಹೆಚ್ಚು ವಿಶ್ವಾಸಾರ್ಹ; ಒಂದು ಐಟಂ ಸಂಕುಚಿಸಲಾಗದಿದ್ದಾಗ, ಅದರ ಕೆಳಗೆ ಪೂರ್ಣ ಕಾರಣ ಕಾಣಿಸುತ್ತದೆ. ಅಳಿಸುವಿಕೆ ಈಗ ಸುರಕ್ಷಿತ: iOS ಅಳಿಸುವ ಪ್ರಾಂಪ್ಟ್ ಅನ್ನು ನೀವು ರದ್ದುಮಾಡಿದರೆ, ಯಾವುದೂ ಮುಕ್ತಗೊಂಡ ಸ್ಥಳವಾಗಿ ಎಣಿಸಲ್ಪಡುವುದಿಲ್ಲ. ಕ್ಲೀನಪ್ ಪರದೆಗಳು ಈಗ ದೊಡ್ಡ ಪಠ್ಯ ಗಾತ್ರದಲ್ಲೂ ಪದಗಳನ್ನು ಕತ್ತರಿಸದೆ ಹೊಂದಿಕೊಳ್ಳುತ್ತವೆ. ಇನ್ನೂ ಹಲವು ಸಣ್ಣ ಸುಧಾರಣೆಗಳು ಮತ್ತು ಉತ್ತಮ ಅನುವಾದಗಳು. ಎಲ್ಲವೂ ಹಿಂದಿನಂತೆ ನಿಮ್ಮ ಸಾಧನದಲ್ಲೇ ನಡೆಯುತ್ತದೆ: ಖಾತೆ ಇಲ್ಲ, ಜಾಹೀರಾತುಗಳಿಲ್ಲ, ಚಂದಾದಾರಿಕೆ ಇಲ್ಲ.",
  ml: "സ്വൈപ്പ് കാർഡുകൾ ഇപ്പോൾ മുഴുവൻ ഫോട്ടോയും കാണിക്കുന്നു, അതിനാൽ വീതിയുള്ള ഷോട്ടുകൾ ഇനി മുറിഞ്ഞുപോകില്ല. വീഡിയോ, ഫോട്ടോ കംപ്രഷൻ കൂടുതൽ വിശ്വസനീയമായി; ഒരു ഇനം കംപ്രസ് ചെയ്യാനാകാത്തപ്പോൾ അതിന് താഴെ പൂർണ്ണ കാരണം കാണിക്കുന്നു. ഇല്ലാതാക്കൽ ഇപ്പോൾ കൂടുതൽ സുരക്ഷിതമാണ്: iOS-ലെ ഇല്ലാതാക്കൽ പ്രോംപ്റ്റ് റദ്ദാക്കിയാൽ, ഒന്നും സ്വതന്ത്രമായ ഇടമായി കണക്കാക്കില്ല. ക്ലീനപ്പ് സ്ക്രീനുകൾ ഇപ്പോൾ വലിയ ടെക്സ്റ്റ് വലുപ്പത്തിലും വാക്കുകൾ മുറിയാതെ യോജിക്കുന്നു. കൂടാതെ നിരവധി ചെറിയ പരിഹാരങ്ങളും മെച്ചപ്പെട്ട വിവർത്തനങ്ങളും. എല്ലാം മുൻപത്തെപ്പോലെ നിങ്ങളുടെ ഉപകരണത്തിൽ തന്നെ പ്രവർത്തിക്കുന്നു: അക്കൗണ്ടില്ല, പരസ്യങ്ങളില്ല, സബ്‌സ്‌ക്രിപ്ഷനില്ല.",
  pa: "ਸਵਾਈਪ ਕਾਰਡ ਹੁਣ ਪੂਰੀ ਫ਼ੋਟੋ ਦਿਖਾਉਂਦੇ ਹਨ, ਇਸ ਲਈ ਚੌੜੀਆਂ ਤਸਵੀਰਾਂ ਹੁਣ ਕੱਟੀਆਂ ਨਹੀਂ ਜਾਂਦੀਆਂ। ਵੀਡੀਓ ਅਤੇ ਫ਼ੋਟੋ ਕੰਪ੍ਰੈਸ਼ਨ ਵਧੇਰੇ ਭਰੋਸੇਯੋਗ ਹੈ, ਅਤੇ ਜਦੋਂ ਕੋਈ ਆਈਟਮ ਕੰਪ੍ਰੈਸ ਨਾ ਹੋ ਸਕੇ, ਤਾਂ ਉਸ ਦੇ ਹੇਠਾਂ ਪੂਰਾ ਕਾਰਨ ਦਿਖਦਾ ਹੈ। ਮਿਟਾਉਣਾ ਹੁਣ ਵਧੇਰੇ ਸੁਰੱਖਿਅਤ ਹੈ: ਜੇ ਤੁਸੀਂ iOS ਦਾ ਮਿਟਾਉਣ ਵਾਲਾ ਪ੍ਰੋਮਪਟ ਰੱਦ ਕਰਦੇ ਹੋ, ਤਾਂ ਕੁਝ ਵੀ ਖਾਲੀ ਹੋਈ ਥਾਂ ਵਜੋਂ ਨਹੀਂ ਗਿਣਿਆ ਜਾਂਦਾ। ਕਲੀਨਅੱਪ ਸਕ੍ਰੀਨਾਂ ਹੁਣ ਵੱਡੇ ਟੈਕਸਟ ਆਕਾਰ ਵਿੱਚ ਵੀ ਸ਼ਬਦ ਕੱਟੇ ਬਿਨਾਂ ਫਿੱਟ ਹੁੰਦੀਆਂ ਹਨ। ਨਾਲ ਹੀ ਕਈ ਛੋਟੀਆਂ ਸੁਧਾਰਾਂ ਅਤੇ ਬਿਹਤਰ ਅਨੁਵਾਦ। ਸਭ ਕੁਝ ਹਾਲੇ ਵੀ ਤੁਹਾਡੇ ਡੀਵਾਈਸ ਉੱਤੇ ਚੱਲਦਾ ਹੈ: ਕੋਈ ਖਾਤਾ ਨਹੀਂ, ਕੋਈ ਇਸ਼ਤਿਹਾਰ ਨਹੀਂ, ਕੋਈ ਸਬਸਕ੍ਰਿਪਸ਼ਨ ਨਹੀਂ।",
  es: "Las tarjetas de deslizamiento ahora muestran la foto completa, así que las tomas panorámicas ya no se recortan. La compresión de vídeos y fotos es más fiable, y cuando un elemento no se puede comprimir, debajo aparece el motivo completo. Borrar es más seguro: si cancelas la confirmación de borrado de iOS, no se cuenta nada como espacio liberado. Las pantallas de limpieza ahora se ajustan a tamaños de texto grandes sin cortar palabras. Además, muchas correcciones pequeñas y mejores traducciones. Todo sigue funcionando en tu dispositivo: sin cuenta, sin anuncios, sin suscripción.",
  fr: "Les cartes de balayage affichent désormais la photo entière, donc les grands angles ne sont plus recadrés. La compression des vidéos et des photos est plus fiable, et lorsqu'un élément ne peut pas être compressé, la raison complète s'affiche dessous. Les suppressions sont plus sûres : si vous annulez la demande de suppression d'iOS, rien n'est compté comme espace libéré. Les écrans de nettoyage s'adaptent désormais aux grandes tailles de texte sans couper les mots. Plus de nombreuses petites corrections et de meilleures traductions. Tout tourne toujours sur votre appareil : aucun compte, aucune pub, aucun abonnement.",
  de: "Swipe-Karten zeigen jetzt das ganze Foto, sodass breite Aufnahmen nicht mehr beschnitten werden. Video- und Fotokomprimierung ist zuverlässiger, und wenn sich ein Element nicht komprimieren lässt, steht darunter der vollständige Grund. Löschen ist sicherer: Wenn du die Löschabfrage von iOS abbrichst, wird nichts als freigegebener Speicher gezählt. Die Aufräumbildschirme passen jetzt auch bei großen Schriftgrößen, ohne Wörter abzuschneiden. Dazu viele kleine Fehlerbehebungen und bessere Übersetzungen. Alles läuft weiterhin auf deinem Gerät: kein Konto, keine Werbung, kein Abo.",
  'pt-BR': "Os cartões de deslizar agora mostram a foto inteira, então fotos panorâmicas não são mais cortadas. A compressão de vídeos e fotos ficou mais confiável, e quando um item não pode ser comprimido, o motivo completo aparece abaixo dele. Excluir ficou mais seguro: se você cancelar o aviso de exclusão do iOS, nada é contado como espaço liberado. As telas de limpeza agora cabem em tamanhos de texto grandes sem cortar palavras. Além disso, várias correções pequenas e traduções melhores. Tudo continua rodando no seu dispositivo: sem conta, sem anúncios, sem assinatura.",
  it: "Le schede di scorrimento ora mostrano la foto intera, quindi gli scatti panoramici non vengono più ritagliati. La compressione di video e foto è più affidabile e, quando un elemento non può essere compresso, sotto appare il motivo completo. Eliminare è più sicuro: se annulli la richiesta di eliminazione di iOS, nulla viene conteggiato come spazio liberato. Le schermate di pulizia ora si adattano ai testi grandi senza tagliare le parole. Inoltre molte piccole correzioni e traduzioni migliori. Tutto continua a girare sul tuo dispositivo: nessun account, nessuna pubblicità, nessun abbonamento.",
  ja: "スワイプカードが写真全体を表示するようになり、横長の写真も切り取られなくなりました。動画と写真の圧縮の信頼性が向上し、圧縮できない項目には、その下に完全な理由が表示されます。削除がより安全になりました。iOS の削除確認をキャンセルすると、解放された容量としてカウントされません。クリーンアップの画面は、大きな文字サイズでも文字が切れずに収まります。そのほか多くの小さな修正と翻訳の改善も含まれます。処理はすべて端末内のまま：アカウント不要、広告なし、サブスクなし。",
  ko: "스와이프 카드가 이제 사진 전체를 보여 주므로, 가로로 긴 사진도 잘리지 않습니다. 동영상과 사진 압축이 더 안정적이 되었고, 항목을 압축할 수 없을 때는 그 아래에 전체 이유가 표시됩니다. 삭제가 더 안전해졌습니다. iOS 삭제 확인 창을 취소하면 아무것도 확보된 공간으로 계산되지 않습니다. 정리 화면이 큰 글자 크기에서도 단어가 잘리지 않고 맞습니다. 그 밖에도 여러 작은 수정과 더 나은 번역이 포함되어 있습니다. 모든 처리는 여전히 기기 안에서: 계정 없음, 광고 없음, 구독 없음.",
  'zh-Hans': "滑动卡片现在会显示完整照片，因此宽幅照片不再被裁剪。视频和照片压缩更可靠，无法压缩的项目下方会显示完整原因。删除更安全：如果取消 iOS 的删除确认，就不会计入已释放的空间。清理页面现在可以在大字体下完整显示，不会截断文字。另有许多小修复和更好的翻译。所有处理依然在你的设备上：无需账号、没有广告、没有订阅。",
  ru: "Карточки смахивания теперь показывают всё фото целиком, поэтому широкие кадры больше не обрезаются. Сжатие видео и фото стало надёжнее: если элемент не удалось сжать, под ним показана полная причина. Удаление стало безопаснее: если вы отмените запрос iOS на удаление, ничего не будет засчитано как освобождённое место. Экраны очистки теперь помещаются при крупном размере текста, и слова не обрезаются. Кроме того, много мелких исправлений и улучшенных переводов. Всё по-прежнему работает на вашем устройстве: без аккаунта, без рекламы, без подписки.",
  ar: "تعرض بطاقات السحب الآن الصورة كاملة، فلم تعد اللقطات العريضة تُقتطع. أصبح ضغط الفيديو والصور أكثر موثوقية، وعندما يتعذر ضغط عنصر ما، يظهر السبب الكامل أسفله. الحذف أكثر أمانًا الآن: إذا ألغيت مطالبة الحذف من iOS، لا يُحتسب أي شيء كمساحة محررة. تتسع شاشات التنظيف الآن لأحجام النص الكبيرة دون قطع الكلمات. إضافةً إلى تحسينات صغيرة كثيرة وترجمات أفضل. كل شيء ما زال يعمل على جهازك: لا حساب، لا إعلانات، لا اشتراك.",
  he: "כרטיסי ההחלקה מציגים עכשיו את התמונה כולה, כך שצילומים רחבים כבר לא נחתכים. כיווץ סרטונים ותמונות אמין יותר, וכשפריט לא ניתן לכיווץ, הסיבה המלאה מופיעה מתחתיו. מחיקה בטוחה יותר: אם מבטלים את אישור המחיקה של iOS, שום דבר לא נספר כמקום שפונה. מסכי הניקוי מתאימים עכשיו גם לגדלי טקסט גדולים, בלי לחתוך מילים. בנוסף, תיקונים קטנים רבים ותרגומים טובים יותר. הכול עדיין רץ במכשיר שלכם: בלי חשבון, בלי פרסומות, בלי מנוי.",
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
