# The interface languages
<!-- id: translation-languages-page; keys: per-language rules, Spanish, Hebrew, Urdu, Persian, glossary doubts, right-to-left; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py -->

Part of [TextMouth's documentation](../../README.md).

What a translator needs to know about each of the 25 languages, beyond the rules for every language in [Translating TextMouth](translation.md#the-rules-for-every-language).

## Spanish
<!-- id: translation-spanish; keys: es, tú, usted, neutral Spanish, Latin America, regional words, glossary, Apple's Spanish; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py -->

One neutral Spanish (`es`) serves every region, until the user says otherwise.
- Use the familiar "tú", never "usted" and never "vos" or "vosotros": "Elige una carpeta", "tu biblioteca".
- Avoid words that differ by country.
  Say "Mac" and "iPhone", not "ordenador" or "computadora" and "móvil" or "celular"; prefer "archivo", "carpeta", "descargar", and "agregar", which every region understands.
- Use the words Apple's own Spanish interface uses where the glossary has them.
- Menu items and buttons use the infinitive ("Reproducir", "Abrir"), hints use the third person ("Reproduce el libro."), and a message to the reader speaks to "tú" ("No se pudo abrir tu archivo.").
- Capitalize as Spanish does, not as English titles do: "Lista de lectura", not "Lista de Lectura".
- Open questions and exclamations with "¿" and "¡".
- Avoid a gendered word where a neutral one reads naturally; where none does, use the form the glossary gives.
- `many` is the exact-millions form: "%lld de libros".
  The usual counts use `one` and `other`.

## Italian
<!-- id: translation-italian; keys: it, tu, Apple's Italian, many; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py -->

- Address the listener as "tu": "Scegli una cartella", "la tua libreria".
- Menu items and buttons use the imperative ("Apri", "Riproduci"); hints use the third person and end with a period ("Riproduce il libro.").
- Sentence case: "Elenco di lettura".
- Plural categories `one`, `many`, `other`; `many` is exact millions ("%lld di libri").

## French
<!-- id: translation-french; keys: fr, vous, no-break space, Apple's French, many; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py -->

- Address the listener as "vous": "Choisissez un dossier", "votre bibliothèque".
- Menu items and buttons use the infinitive ("Ouvrir", "Lire"); hints use the third person and end with a period ("Lit le livre.").
- Sentence case.
  A no-break space (U+00A0) goes before `:`, `;`, `?`, and `!` and inside « », never a plain space.
- Plural categories `one`, `many`, `other`; `one` covers 0 and 1 and keeps the number, and `many` is exact millions ("%lld de livres").

## Brazilian Portuguese
<!-- id: translation-portuguese-brazil; keys: pt-BR, você, Brazilian words, Apple's Portuguese, many; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py -->

- Address the listener as "você": "Escolha uma pasta", "sua biblioteca".
- Menu items and buttons use the infinitive ("Abrir", "Reproduzir"); hints use the third person and end with a period ("Reproduz o livro.").
- Brazil's words and spelling ("arquivo", "tela", "excluir"), never Portugal's.
- Plural categories `one`, `many`, `other`; `one` covers 0 and 1 and keeps the number, and `many` is exact millions ("%lld de livros").

## German
<!-- id: translation-german; keys: de, du, capitalized nouns, long words, Apple's German; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py -->

- Address the listener as "du", as Apple's German does: "Wähle einen Ordner", "deine Bibliothek".
- Menu items and buttons use the infinitive ("Öffnen", "Wiedergeben"); hints use the third person and end with a period ("Gibt das Buch wieder.").
- Nouns are capitalized; quotation marks are „…“.
- German runs long: take the shorter of two good words, and never a compound a button label cannot hold.
- Plural categories `one`, `other`.

## Russian
<!-- id: translation-russian; keys: ru, вы, Cyrillic, few, many, Apple's Russian; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py -->

- Address the listener formally, "вы" in lower case: "Выберите папку", "ваша книга".
- Menu items and buttons use the infinitive ("Открыть", "Воспроизвести"); hints use the third person and end with a period ("Воспроизводит книгу.").
- Quotation marks «…»; use "ё" only where Apple's Russian does, and consistently.
- Plural categories `one` (1, 21, not 11), `few` (2 to 4, 22 to 24), `many` (0, 5 to 20, 25 to 30), and `other` (a fraction); every form keeps the number.

## Ukrainian
<!-- id: translation-ukrainian; keys: uk, ви, Cyrillic, apostrophe, few, many; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py -->

- Ukrainian words and spelling, never Russian ones; address the listener formally, "ви": "Виберіть папку", "ваша бібліотека".
- Menu items and buttons use the infinitive ("Відкрити", "Відтворити"); hints use the third person and end with a period ("Відтворює книгу.").
- Quotation marks «…»; the apostrophe inside a word is the typographic one (U+2019), everywhere.
- Plural categories `one`, `few`, `many`, `other`, as in Russian; every form keeps the number.

## Simplified Chinese
<!-- id: translation-chinese; keys: zh-Hans, Mandarin, full-width punctuation, measure word, Apple's Chinese; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py -->

- Mainland Simplified Chinese as Apple writes it; address the listener as "你" where a sentence needs it.
- Full-width punctuation in Chinese text (，。：；？！“”（）), and a space between Chinese characters and a Latin word or a placeholder: "在 Mac 上", "%lld 本书".
- Labels are short noun or verb phrases ("打开", "播放"); hints are sentences that end with "。".
- One plural category, `other`, with the number and the right measure word.

## Japanese
<!-- id: translation-japanese; keys: ja, polite style, katakana, counters, Apple's Japanese; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py -->

- The polite style (です・ます) in sentences, hints, and messages ("ブックを再生します。"); labels and menu items as Apple writes them ("開く", "再生").
- Full-width punctuation (、。「」); loanwords in katakana as Apple spells them (ライブラリ, フォルダ).
- One plural category, `other`, with the number and the right counter (冊, 件, 個, 分).

## Korean
<!-- id: translation-korean; keys: ko, Hangul, particles, polite endings, Apple's Korean; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py -->

- Polite formal endings in sentences, hints, and messages ("책을 재생합니다."); labels and menu items as Apple writes them ("열기", "재생").
- Where a placeholder's last sound is unknown, write both particle forms, as Apple's Korean does: "%@을(를)", "%@이(가)".
  A name takes its particle straight against it ("TextMouth가").
- One plural category, `other`, with the number and the right counter (권, 개, 분).

## Hindi
<!-- id: translation-hindi; keys: hi, Devanagari, आप, danda, Apple's Hindi; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py -->

- Devanagari, addressing the listener as "आप"; menu items and buttons as Apple writes them ("खोलें", "चलाएँ", "रद्द करें"); hints in the third person ("पुस्तक चलाता है।").
- Sentences end with "।"; Mac, iPhone, and the glossary's names stay in Latin letters.
- Plural categories `one` and `other`; `one` covers 0 and 1 and keeps the number.

## Arabic
<!-- id: translation-arabic; keys: ar, right-to-left, RTL, Modern Standard Arabic, mirrored layout, Apple's Arabic; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py; status: incomplete; issues: Q18 -->

- Modern Standard Arabic as Apple's Arabic interface writes it: commands in Apple's form, hints in the third person, and the punctuation (، ؛ ؟) and quotation marks Apple's Arabic uses.
- Arabic is the app's first right-to-left language, with Hebrew, Urdu, and Persian.
  A string holds no direction marks: Foundation lays the text out, SwiftUI mirrors the layout, and a Latin name or a placeholder stays as it is inside the text.
- Plural categories `zero` (0), `one` (1), `two` (2), `few` (3 to 10), `many` (11 to 99, by the last two digits), and `other`; every form keeps the number.
- No test yet looks at a mirrored window of any of the four right-to-left languages, so the layout is unchecked.

## Bengali
<!-- id: translation-bengali; keys: bn, Bengali script, আপনি, Apple's Bengali; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py -->

- Bengali script, addressing the listener as "আপনি"; commands and hints as Apple's Bengali would write them; sentences end with "।".
- Plural categories `one` and `other`; `one` covers 0 and 1 and keeps the number.

## Indonesian
<!-- id: translation-indonesian; keys: id, Anda, base form, Apple's Indonesian; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py -->

- Address the listener as "Anda"; commands in the base form ("Buka", "Putar", "Batalkan"); hints in the third person ("Memutar buku.").
- One plural category, `other`; a noun after a number stays singular ("%lld buku").

## Vietnamese
<!-- id: translation-vietnamese; keys: vi, bạn, Apple's Vietnamese, Hiển thị; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py -->

- Address the listener as "bạn"; commands as Apple writes them ("Mở", "Phát", "Hủy"); hints are sentences that end with a period.
- One plural category, `other`: Foundation on macOS 26.3 gives Vietnamese no other form, though CLDR 49 gives it `one`.
- The consistency pass settled "Hiển thị" for Show everywhere, with the control's name in quotation marks inside a sentence.

## Turkish
<!-- id: translation-turkish; keys: tr, apostrophe, suffix, kelime, Apple's Turkish; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py -->

- Commands in the imperative ("Aç", "Oynat", "Vazgeç"); hints in the third person ("Kitabı oynatır."); a sentence that addresses the listener uses Apple's polite form.
- A suffix on a name takes an apostrophe ("TextMouth'u", "Mac'te"), but not after a translated name such as "Çöp Sepeti" or "Okuma Listesi"; a noun after a number stays singular.
- Plural categories `one` (exactly 1) and `other`; the two forms are usually the same text.
- The consistency pass settled "kelime" for word (not "sözcük") and quotation marks around a control's name held by a placeholder.

## Thai
<!-- id: translation-thai; keys: th, no spaces, full stop, Apple's Thai; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py -->

- No space between words, a space between phrases and around Latin words and numbers; no polite particles; commands as Apple writes them ("เปิด", "เล่น", "ยกเลิก").
- No full stop ends a sentence, as in Apple's Thai.
- One plural category, `other`.

## Polish
<!-- id: translation-polish; keys: pl, few, many, Macu, glued ending, Apple's Polish; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py; status: incomplete; issues: TL21 -->

- Commands in the imperative ("Otwórz", "Odtwórz", "Anuluj"); hints in the third person ("Odtwarza książkę."); quotation marks „…”.
- Plural categories `one` (exactly 1), `few` (2 to 4, 22 to 24, 32 to 34, not 12 to 14), `many` (0, 5 to 21, 25 to 31), and `other` (a fraction); every form but `one` keeps the number.
- The name check refuses a name with an ending glued on ("Macu"), so translators write "komputer Mac" instead.
  A follow-up may let Polish endings through.

## Traditional Chinese
<!-- id: translation-chinese-traditional; keys: zh-Hant, Taiwan, 檔案夾, Apple's Traditional Chinese; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py -->

- Taiwan's Traditional Chinese as Apple writes it (資料夾, 檔案, 設定, 播放, 書籤, 搜尋), never Simplified words converted character by character; address the listener as "你".
- The consistency pass settled 檔案夾 for a folder, as Apple's Finder writes it.
- Full-width punctuation (，。：；？！「」（）) and a space between Chinese and a Latin word or a placeholder.
- One plural category, `other`.

## Dutch
<!-- id: translation-dutch; keys: nl, je, Apple's Dutch; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py -->

- Address the listener as "je"; menu items and buttons as Apple writes them ("Open", "Speel af", "Annuleer"); hints in the third person ("Speelt het boek af.").
- Plural categories `one` and `other`.

## Swedish
<!-- id: translation-swedish; keys: sv, du, Macen, glued ending, Apple's Swedish; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py; status: incomplete; issues: TL21 -->

- Address the listener as "du"; commands in the imperative ("Öppna", "Spela upp", "Avbryt"); hints in the third person ("Spelar upp boken."); quotation marks ”…”.
- The name check refuses a name with an ending glued on ("Macen", "TextMouths"), so translators write "Mac-datorn" instead.
- Plural categories `one` and `other`.

## Hebrew
<!-- id: translation-hebrew; keys: he, right-to-left, RTL, gendered forms, Apple's Hebrew; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py; status: incomplete; issues: Q18 -->

- Apple's Hebrew: commands in the forms its interface uses, hints in the third person, a gendered form avoided where Apple avoids it, and its quotation marks and punctuation.
- Right to left, with no direction marks; the mirrored layout is unchecked (see Arabic).
- Plural categories `one` (exactly 1), `two` (exactly 2), and `other`.

## Urdu
<!-- id: translation-urdu; keys: ur, right-to-left, RTL, Arabic script, ک ی ہ, look-alike letters, Windows and Android; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py -->

- Urdu's own letters ک, ی, and ہ (and ے and ھ where Urdu writes them), never the Arabic look-alikes ك, ي, and ه, which a screen reader and a braille table read as Arabic.
- Address the listener as "آپ"; commands in the polite imperative ("کھولیں", "چلائیں", "منسوخ کریں"); hints in the third person ("کتاب چلاتا ہے۔"); sentences end with "۔" and the comma is "،".
- Right to left, with no direction marks; the mirrored layout is unchecked (see Arabic).
- Plural categories `one` (exactly 1) and `other`; both keep the number.
- macOS has no Urdu interface, so the glossary uses Apple's word where the translators knew it, and otherwise the word Windows and Android use.
  The doubtful ones (the braille contraction words, "ہدایت" for Hint, "چھوڑیں" for Quit) are marked `"check": true`.
- Spoken key names are written in Urdu letters.

## Persian
<!-- id: translation-persian; keys: fa, right-to-left, RTL, Arabic script, ZWNJ, zero-width non-joiner, ezafe, look-alike letters; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py -->

- Persian's own letters ک and ی, never the Arabic look-alikes ك, ي, and ى.
- The zero-width non-joiner (U+200C) goes where Persian spells one ("می‌کند", "کتاب‌ها"), never a plain space or a joined form.
- Address the listener as "شما" in sentences ("یک پوشه انتخاب کنید"); menu items and buttons as verbal nouns ("باز کردن", "پخش", "لغو"); hints in the third person; sentences end with "." and quotation marks are «…».
- Right to left, with no direction marks; the mirrored layout is unchecked (see Arabic).
- Plural categories `one` (0 and 1, as in Hindi) and `other`; a noun after a number stays singular, so the two forms are usually the same text.
- macOS has no Persian interface, so the glossary uses Apple's word where the translators knew it, and otherwise the word Windows and Android use.
  The doubtful ones (Feed "فید", Track "تراک", Import and Export "وارد کردن" and "صادر کردن", Remove "برداشتن" against Delete "حذف") are marked `"check": true`.
- A literal number of the English stays in ASCII digits.
- The consistency pass settled "در حال آماده‌سازی" for Loading and the ezafe written "ه‌ی".
