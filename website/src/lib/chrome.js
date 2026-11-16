// Chrome strings (header, footer, menus, skip link) for each localized page.
// Source of truth: scripts/localization/site/site-translations/<code>.chrome.json.
// en.chrome.json lists every key; scripts/lib/chrome.test.mjs checks that each
// language file has the same keys. English returns the key itself.
// Non-English values are model-translated and need a native-speaker review.

import de from "../../scripts/localization/site/site-translations/de.chrome.json";
import fr from "../../scripts/localization/site/site-translations/fr.chrome.json";
import es from "../../scripts/localization/site/site-translations/es.chrome.json";
import it from "../../scripts/localization/site/site-translations/it.chrome.json";
import pt_BR from "../../scripts/localization/site/site-translations/pt-BR.chrome.json";
import ja from "../../scripts/localization/site/site-translations/ja.chrome.json";
import ko from "../../scripts/localization/site/site-translations/ko.chrome.json";
import zh_Hans from "../../scripts/localization/site/site-translations/zh-Hans.chrome.json";
import ru from "../../scripts/localization/site/site-translations/ru.chrome.json";
import ar from "../../scripts/localization/site/site-translations/ar.chrome.json";
import he from "../../scripts/localization/site/site-translations/he.chrome.json";
import hi from "../../scripts/localization/site/site-translations/hi.chrome.json";
import bn from "../../scripts/localization/site/site-translations/bn.chrome.json";
import ta from "../../scripts/localization/site/site-translations/ta.chrome.json";
import te from "../../scripts/localization/site/site-translations/te.chrome.json";
import mr from "../../scripts/localization/site/site-translations/mr.chrome.json";
import gu from "../../scripts/localization/site/site-translations/gu.chrome.json";
import kn from "../../scripts/localization/site/site-translations/kn.chrome.json";
import ml from "../../scripts/localization/site/site-translations/ml.chrome.json";
import pa from "../../scripts/localization/site/site-translations/pa.chrome.json";

const TABLES = {
  "de": de,
  "fr": fr,
  "es": es,
  "it": it,
  "pt-BR": pt_BR,
  "ja": ja,
  "ko": ko,
  "zh-Hans": zh_Hans,
  "ru": ru,
  "ar": ar,
  "he": he,
  "hi": hi,
  "bn": bn,
  "ta": ta,
  "te": te,
  "mr": mr,
  "gu": gu,
  "kn": kn,
  "ml": ml,
  "pa": pa,
};

/** Translated chrome text for a language code; English (or a missing key) returns the English text. */
export function chrome(code, text) {
  return TABLES[code]?.[text] ?? text;
}
