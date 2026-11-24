# Describing pictures in TextMouth (research, November 24, 2026)

Your question:

> Speaking of picture descriptions, does Mac OS / iOS expose the apis for getting objects and descriptions of an image like what voice over gets with vo-shift-l?
> I am curious if we can figure out if those are available to extract text and to make captions for images better for pdfs and I guess other formats that include images like we do for transcriptions.

## How this was researched

- Apple's current developer documentation was read through its public JSON mirror (`developer.apple.com/tutorials/data/documentation/...`), and the SDK headers and Swift interfaces of Xcode 26.0.1 on this Mac.
- Probes were small Swift scripts, each under a time limit, that never trap, show no window, and ask for no permission.
  They ran only on pictures drawn by code: emoji artwork, a bar chart, a flow diagram, a captioned figure, a table, a QR code, a Code 128 barcode, and a drawn scene.
  One TextMouth fixture, the made `TestData/format-samples/png/page-one.png`, was read as well.
- This Mac runs macOS 26.3.1 on an M3, so everything new in iOS and macOS 27 was read in the documentation and could not be run.
- Apple Intelligence is off on this Mac, so the on-device language model refused every prompt (`appleIntelligenceNotEnabled`); its sentences were not measured, and the probe did not turn it on.
- No photograph was probed, because no photograph with a license that allows it is in `TestData/`; every judgment about photographs rests on the documentation and is marked.
- Nothing was downloaded and run, and no model was downloaded; model cards were only read.
- "Measured" marks a number from this Mac today, "documented" a claim from a source linked beside it, and "unchecked" one I could not confirm.

## Summary

- No public API gives VoiceOver's description.
  VO-Shift-L asks Apple Intelligence by default, or a lesser on-device mode if you choose it, and only VoiceOver can ask.
- Public APIs give the parts: Vision's picture kind and labels, text, tables, and codes, on every system TextMouth supports; none gives a sentence.
- Foundation Models takes images on iOS and macOS 27 and nothing earlier ([Attachment](https://developer.apple.com/documentation/foundationmodels/attachment)); that is the first public way to a real caption, on the device.
- On 26 its model is text only, so it can only turn Vision's findings into a sentence; on a Mac 14 or 15 it does not exist.
- Measured: Vision names a chart, a diagram, a printed page, text, a table, and codes well and fast (6 to 120 ms after a 1.6 s start), and names a picture's subject poorly (a drawn dog came back as a squirrel and a kangaroo).
- So TextMouth should describe in three tiers: facts from Vision everywhere, a sentence from the language model where it exists, and a caption from the picture where iOS and macOS 27 allow.
- Descriptions are kept like transcripts: a record in the book's package, marked as the computer's, editable, made again on request, never sent off the device.
- The tier that matters most for a blind reader is the first: say that a picture is a chart, read its text and table, and say so plainly when nothing can be said.
- Nothing needs a private API or a downloaded model.

## What VoiceOver uses

- The Mac's guide says "VoiceOver can describe images in apps and on websites", asked with VO-Shift-L on an image, and "By default, image descriptions use Apple Intelligence" ([VoiceOver User Guide](https://support.apple.com/guide/voiceover/vocbaf20181f/mac)).
- On-Device Mode keeps the processing on the Mac, "may cause image descriptions to be less detailed", and needs one download the first time.
- The iPhone's page lists Image Descriptions, Screen Recognition, and Text Recognition as VoiceOver Recognition ([Apple Support](https://support.apple.com/111799)); that page does not say where the processing runs.
- Apple's May 2026 announcement adds an Image Explorer that "uses Apple Intelligence to give more detailed descriptions of images systemwide", and does not say whether it runs on the device.
  Source: [Apple newsroom, May 2026](https://www.apple.com/newsroom/2026/05/apple-unveils-new-accessibility-features-and-updates-with-apple-intelligence/).
- Whether the default mode runs on the device or on Apple's servers is therefore unchecked; community posts on AppleVis say Private Cloud Compute is used unless On-Device Mode is on, which no Apple page confirms.
- None of these is a public API.
  An app cannot ask VoiceOver to describe an image, and cannot read what VoiceOver says.
- TextMouth shows its books as text, so no picture ever reaches VoiceOver from TextMouth; a description has to be made before the text is read.
- Searches of Apple's documentation, WWDC26's session 237, and AppleVis found no developer API for alt text or for VoiceOver's descriptions.
  I do not propose a private one.

## The public APIs, one by one

- **Accessibility framework:** it lets an app give VoiceOver information, set braille and audio graphs, and translate braille; it has no call that describes a picture ([Accessibility API](https://developer.apple.com/documentation/accessibility/accessibility-api)).
- **VisionKit's `ImageAnalyzer`:** it finds "subjects, text, and QR codes" for the Live Text interface, and `ImageAnalysis` offers `transcript`, not a caption ([ImageAnalyzer](https://developer.apple.com/documentation/visionkit/imageanalyzer)); macOS 13 and iOS 16.
  Measured: its text matched Vision's, and it found no QR code that Vision's barcode request read.
- **Vision, older `VN…Request` API:** `VNClassifyImageRequest` (macOS 10.15, iOS 13), `VNRecognizeTextRequest` (10.15; automatic language detection 13), `VNDetectBarcodesRequest` (10.13), `VNRecognizeAnimalsRequest`, `VNDetectHumanRectanglesRequest`, saliency (10.15).
  Versions are from the SDK headers; the API is listed under [Original API](https://developer.apple.com/documentation/vision/original-objective-c-and-swift-api).
  A Mac on 14 has all of them.
- **Vision, Swift API:** the same requests without the `VN` prefix, `ClassifyImageRequest`, `RecognizeTextRequest`, `DetectBarcodesRequest` from macOS 15 and iOS 18 ([ClassifyImageRequest](https://developer.apple.com/documentation/vision/classifyimagerequest)).
- **Vision, new on 26:** `RecognizeDocumentsRequest` returns a document's paragraphs, tables, lists, and barcodes ([RecognizeDocumentsRequest](https://developer.apple.com/documentation/vision/recognizedocumentsrequest)); macOS 26 and iOS 26.
- **Vision's two tools for the language model:** `OCRTool` and `BarcodeReaderTool`, which a model session may call; macOS and iOS 27 ([OCRTool](https://developer.apple.com/documentation/vision/ocrtool)).
- **No request in Vision describes or captions a picture;** the framework's own list of tasks has none ([Vision](https://developer.apple.com/documentation/vision)).
- **Core ML:** Apple's own model page offers classifiers, depth, segmentation, detection, and question answering, and no captioner ([models](https://developer.apple.com/machine-learning/models/)).

## Foundation Models

- The on-device model on 26 is text only: its documentation calls it "the on-device text foundation model", and the 26.0 SDK on this Mac has no image attachment type ([SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel)).
- On 27, `Attachment` carries a `CGImage` or an image file's URL, the two kinds of image its page names (checked against Apple's page on November 24); `Attachment` and `ImageAttachmentContent` both say macOS and iOS 27.0.
  Source: [Analyzing images with multimodal prompting](https://developer.apple.com/documentation/foundationmodels/analyzing-images-with-multimodal-prompting).
- That page lists "Generating accessibility descriptions for images that you share on the web" as a use, and WWDC26 session 237 shows `Prompt { "Generate a caption for this image"; Attachment(image) }` ([session 237](https://developer.apple.com/videos/play/wwdc2026/237)).
- The document says "All AFM models are capable of text and image understanding", and "Smaller AFM models run entirely on-device" ([Detecting available models](https://developer.apple.com/documentation/foundationmodels/detecting-available-apple-foundation-models)).
- The 27 models: AFM Core (about 3 billion parameters, 4 to 8K tokens), and on newer hardware AFM Core Advanced (about 20 billion, 8K).
- The Cloud model, `PrivateCloudComputeLanguageModel`, needs an entitlement TextMouth does not hold; the proposal never uses it.
- A WWDC26 question-and-answer says the token limit stays 4096 with images; unchecked, because I could not read that transcript myself.
- Devices, from the same page:
  - AFM Core: iPhone 15 Pro and Pro Max, all iPhone 16, iPhone 17; iPad mini with A17 Pro, iPads with M1 or later; Macs with M1 or later.
  - Core Advanced on 27: iPhone Air and iPhone 17 Pro, iPads with M4 or later, Macs with M3 or later.
  - The Apple Watch has neither.
- Regions: Apple Intelligence is not working on devices bought in mainland China or used there with a China account; the EU is covered on the 27 releases ([Apple Support](https://support.apple.com/en-us/121115)).
- On 27, "Apple Intelligence is on by default and can no longer be turned off" (the same Detecting page), so the off switch that blocked this Mac stops mattering on 27.
- Languages: measured on this Mac, `supportedLanguages` returned 23 locales.
  They are Danish, German, English (AU, GB, US), Spanish (Spain, Latin America, US), French (France, Canada), Italian, Japanese, Korean, Norwegian Bokmal, Dutch, and Portuguese (Brazil, Portugal).
  Also Swedish, Turkish, Vietnamese, and Chinese (Simplified, and Traditional for Hong Kong and Taiwan).
- Arabic, Urdu, Persian, and some other languages of TextMouth's 25 are not on that list, and `supportsLocale` said false for Arabic.
- The model answers in the language the instructions name, "You MUST respond in Spanish" ([Supporting languages](https://developer.apple.com/documentation/foundationmodels/supporting-languages-and-locales-with-foundation-models)).
- Quality and speed of the 27 caption are unmeasured here and are not published; the session says only that "models tend to do well with descriptive tasks".
- Guardrails may refuse a picture, as they refuse text; the code must treat `guardrailViolation` as "no description".

## What each API gave for a real picture

- Method: `probevision.swift` and `probeswift.swift` ran the requests on the pictures above; times are this M3's, after a first call of about 1.6 seconds that loads the models.
- `VNClassifyImageRequest` knows 1,303 English identifiers such as `adult_cat` and `house_single`, returns a confidence for each, and gives a parent the score of its child (a bicycle scored 0.76, vehicle and machine 0.77).
- Measured, pictures of things (Apple's emoji artwork, which is not a photograph):
  - bicycle: bicycle 0.76, tricycle 0.26, wheel 0.12; right;
  - airplane: airplane and aircraft 0.49; right;
  - car: toy 0.55, car 0.30, van 0.28; close;
  - house: structure 0.46, door 0.20, chimney 0.06, house_single 0.06; near;
  - pizza: pepperoni and meat 0.08, pizza 0.04; weak;
  - dog: animal 0.12, squirrel 0.12, kangaroo 0.04; wrong; cat: fox 0.07, feline 0.06, cat 0.06; unsure; tree: broccoli 0.05; wrong.
- Measured, pictures of paper:
  - bar chart: document, chart, diagram all 0.90; its nine text lines read with confidence 1.00 (the "Q1" to "Q4" labels 0.50);
  - flow diagram: document 0.23, chart and diagram 0.17; its three words read exactly;
  - printed page (the fixture): document 0.38, printed_page 0.36, screenshot 0.23; all eight lines read exactly.
- `RecognizeDocumentsRequest` read the drawn table as one table with four rows (`Item | Qty | Price`, and the three data rows), and the chart's title as a title; it took 2.1 s on the table and 0.3 s on the chart.
- `VNDetectBarcodesRequest` read the QR code (`https://example.org/a-test-page`) and the Code 128 (`TM-0042-IMG`) exactly.
- Saliency gave the salient box of each picture in fractions of its size; the drawn scene gave two boxes, the house and the tree and sun, which could order what is mentioned first.
- `VNRecognizeAnimalsRequest`, the people request, and the face request found nothing in artwork (expected; no photograph was available).
- `VNCalculateImageAestheticsScoresRequest` (macOS 15) flagged the bar chart as a utility image (`isUtility`), which is another signal for "this is a figure, not a picture".
- Vision's text recognition, measured, lists 30 language identifiers, among them English, French, Italian, German, Spanish, Portuguese, Chinese, Cantonese, Korean, Japanese, Russian, Ukrainian, Thai, Vietnamese, Arabic, Turkish, Indonesian, and Swedish.
- The sentence step could not be run: the language model refused on this Mac.
  The probe (`probefm.swift`) holds four prompts of labels and text, and a Spanish one, ready for a Mac with Apple Intelligence on.

## How good a description can be built

- For a chart, diagram, table, page, slide, or code, Vision alone gives a good description: the kind, the title, every word, the table's cells, the code's content.
  A person reading with VoiceOver gets nearly what a sighted reader gets from the words, and the kind tells them what they are looking at.
- For a photograph, the labels alone give a list, not a description, and the drawn dog shows the danger: a wrong label spoken as fact misleads a reader who cannot check.
- Rule: speak a label only when its confidence is high (the bicycle's 0.76 passes; the dog's 0.12 does not), and otherwise say what is certain: "Picture, no description."
- The language model turning labels and text into a sentence could only raise fluency, not accuracy; on 26 it must be told to use only the evidence, and its sentence checked for words absent from the evidence.
- A caption straight from the picture (27) can say what labels cannot (who is doing what), and can also be wrong; so it is marked as the computer's, and the reader keeps the choice.
- Unchecked: how often the 27 caption errs on photographs, and its speed; both need a Mac or iPhone on 27 with the SDK, which this one does not have.

## The options compared

| Option | Needs | Gives | Cost | Verdict |
|---|---|---|---|---|
| Vision facts (kind, text, tables, codes) | Mac 14, iPhone 26 | Facts, not sentences | Code only; 6 to 2,000 ms a picture | Do first |
| Vision labels in a template | Mac 14, iPhone 26 | "Picture of: bicycle" | 60 lines to translate | Only above a confidence |
| Language model writes from Vision facts | OS 26, Apple Intelligence | Fluent sentence, 23 languages | Seconds a picture; unmeasured | Second |
| Language model captions the picture | OS 27, Apple Intelligence | A real caption | Needs the 27 SDK; unmeasured | Third, when the SDK exists |
| Core ML captioner (SmolVLM, Florence-2) | Any, plus a model | A caption, English | 0.5 GB or more; conversion work | Not now |
| Cloud service | A network | Better captions | Sends the user's books away | Never |
| VoiceOver's description | Nothing public | None | Not available | Impossible |

## The open models, for the record

- SmolVLM-256M-Instruct: Apache 2.0, about 0.3 billion parameters, `model.safetensors` 513 MB, English only, captions and questions ([model card](https://huggingface.co/HuggingFaceTB/SmolVLM-256M-Instruct)).
- Florence-2-base: MIT, about 0.23 billion parameters, tasks `<CAPTION>`, `<DETAILED_CAPTION>`, `<MORE_DETAILED_CAPTION>`, and OCR ([model card](https://huggingface.co/microsoft/Florence-2-base)).
- BLIP base captioning: BSD-3-Clause, and its card says "for research purposes only" ([model card](https://huggingface.co/Salesforce/blip-image-captioning-base)).
- Apple's FastVLM: its model license limits use to "non-commercial scientific research", so it is out ([LICENSE_MODEL](https://github.com/apple/ml-fastvlm/blob/main/LICENSE_MODEL)).
- Each would add about 0.25 to 0.5 GB to an app that is 22 MB, need a Core ML conversion of a generative model, and caption in English only; their accuracy was not tested, and none was downloaded.
- They are the only way to a caption on a Mac 14 or 15, or with Apple Intelligence off, so the question stays open (question 4).

## Where TextMouth would use it: the formats

- What is read today: HTML, EPUB, DAISY, Kindle, and ODT pictures are read as their alt text or description when there is one, and as nothing when the author gave none (`HTMLToMarkdownConverter`, `KFXWalk`, `ODTContentReader`; a DOCX picture's description likewise).
- PDF: text drawn in a picture is read by Vision on the regions where the page draws images (`PDFPageImageScanner`, `PDFRecognitionPlan`, `VisionTextRecognition`); a picture with no text gives nothing, and a tagged PDF's own figure alt text is not read.
  The structure tree's `/Alt` on a figure is a free first source, readable through Core Graphics' PDF dictionaries; unchecked, and a spike should confirm it.
- EPUB, HTML in archives, DAISY, DOCX, ODT, Kindle: a picture with empty or missing alt is a candidate; its bytes are in the package (EPUB `src`, DOCX `r:embed`, ODT `draw:image`), and the parser knows where it stands in the text.
- Slides and spreadsheets: a PowerPoint picture's `descr` and its image are the Office reader's matter (`officeresearch`); the picture code below would serve them unchanged.
- Pictures of pages and comic archives (FMT34): already read with Vision (`PageImageReader`); a picture whose text is empty is where a description would help, and a classification of "document" or "printed_page" says to read it instead.
- Comics: panels and balloons are a different task; a caption of the whole page says little, so comics stay as they are for now (question 8).

## How descriptions would be kept

- Like a transcript: transcript.json is a record in the package that the user's edits and a cleanup change, and content.md with its index is the cache built from it ([Transcripts](../docs/architecture/state/package-records-places-and-files.md)).
- A new record, `descriptions.json`, in the package, holding for each picture:
  - where it is (the chapter and the picture's order, and a digest of its bytes so a re-read finds it again);
  - the text, and its source: `author` (the book's own alt), `machine`, or `edited`;
  - the tier and engine that made it, the OS version, the language, and when;
  - for a machine one, the evidence it came from (kind, labels with confidence, text), so a later better engine can say what changed.
- The description reaches the reading text through the same path as a transcript's text: the converter writes it at the picture's place in content.md, marked by an inert comment like the page markers (`MarkdownMarker`), so search, speech, braille, export, and places all see it.
- Machine descriptions are never mixed with the author's: the author's alt wins, and is never overwritten.
- Editable: Edit Text changes it as it changes a transcript (`TranscriptStore.takeEdit` is the model); an edit turns `machine` into `edited`, and an edited one is not replaced without asking.
- Made again on request: a "Describe Pictures Again…" command like Retranscribe Audio…, naming what exists, with Delete Descriptions…, and the previous file kept for an undo, as a transcript's cleanup keeps `transcript.json.before-cleanup`.
- A re-read of the book keeps descriptions whose digest still matches and drops the rest.
- On the iPhone the same files and commands; the record is the shared package format, so a book described on a Mac shows its descriptions on the phone, and the reverse.

## Language, time, battery, privacy

- **Language:** Tier 1's kind words ("chart", "table", "picture") and the template are in TextMouth's 25 interface languages, a short fixed set; Vision's 1,303 labels are English only, so labels are spoken only in English, marked with their language.
- The language model writes in any of its 23 languages by instruction; for the other languages of TextMouth's 25 the description is English and carries `language: en`, so speech may use an English voice for it (whether the speech code can switch voices for one passage is unchecked, question 5).
- **Time, measured:** first Vision call about 1.6 s; classification 6 to 120 ms; text on a page 0.4 s; a table through `RecognizeDocumentsRequest` 2.1 s; saliency under 30 ms.
  A book of 200 pictures costs under a minute of Vision on this M3 (estimate).
- The language model's time is unmeasured; plan on seconds a picture and show progress, which is why it runs on request with Cancel, as transcription does, and never silently at import.
- **Battery on the iPhone:** run only in the foreground with progress, pause on Low Power Mode and on serious thermal state (`ProcessInfo.isLowPowerModeEnabled`, `thermalState`), and offer "only while charging" for a long book; estimate, not measured.
- **Privacy:** Vision, VisionKit, and the on-device Foundation Models model run on the device; nothing is sent, nothing needs a network, and the language model's files are managed by the system.
- A test guard fails the build if code names `PrivateCloudComputeLanguageModel` or a network type in the description code; the entitlement the cloud model needs is not in TextMouth's.
- An image's pixels and descriptions are not written to the log; the log says only counts and tiers, as `TranscriptionLog` does.

## Both platforms, and what a Mac on 14 or 15 gets

- Mac 14.0 (the target): Vision's older requests, the whole of Tier 1 (kind, text, codes, saliency); Swift-API classification only from 15; `ImageAnalyzer` from 13; table recognition and the language model do not exist.
- Mac 15: the same, plus the Swift classification API and the aesthetics score.
- Mac 26: adds `RecognizeDocumentsRequest` (tables) and the text-only language model, which needs Apple Intelligence on and a Mac with M1 or later.
- Mac 27: adds the image caption; the Core Advanced model needs M3 or later.
- iPhone 26.0 (the target): everything Mac 26 has, on an iPhone 15 Pro or later for the model; an iPhone without Apple Intelligence gets Tier 1.
- iPhone 27: the image caption, and the Core Advanced model on an iPhone Air or 17 Pro.
- Every call is behind `#available` and a run-time check (`SystemLanguageModel.default.availability`); code for 27 needs an Xcode with the 27 SDK, and until then is written but not compiled, which is a risk below.
- Both apps share one `PictureDescriber` in the shared sources, as `VisionTextRecognition` is shared today; only the settings pages and the sheets differ.

## How a description is read

- Speech: the picture's place in the text says one line, as a page marker says a page: "Image, described by the computer: a bar chart titled Quarterly sales. Text in the image: ...".
- The author's own alt reads as "Image: ..." with no mention of a machine; an edited one reads as the author's, since the user vouched for it.
- A picture with nothing to say reads "Image, no description", so a listener knows something is there; a setting can turn that line off.
- Settings (a pop-up, every value spoken): Pictures read: "Author's descriptions only" (the default for books never described), "Descriptions, including the computer's", or "Not at all"; a switch "Say that the computer wrote it", on.
- Braille display: the same words, with the machine mark short ("img, computer:"); a transcriber's-note frame (`.<` and `.>` in ASCII braille) is the print-braille convention for text a reader did not write, and fits an exported BRF; whether it fits a live display is a question for the user.
  Source: [BANA Formats 2016, section 3](https://www.brailleauthority.org/formats/2016manual-web/section03.html); a search result quoting that manual gives the ASCII symbols; the dot numbers are unchecked.
- Navigation: a picture is a stop for next and previous heading-like jumps only if the user turns it on; the first version adds none, so no new key is needed.
- Every text of this is a line in an `InterfaceText.line` wording enum, translated into all 24 languages before the merge, as the translation rule requires.
- Nothing is told only by sight: no badge without a spoken label, the sheet's focus and announcements follow the Transcribe Audio sheet.

## Recommendation

- Build Tier 1 first, on both platforms, as "Describe Pictures…" for a book, with the record, the marker, the edit and again flows of transcripts.
- Add the language model's sentence on 26 (labels and text in, one sentence out, English and 22 other languages), with the evidence check.
- Add the 27 caption when Xcode's 27 SDK is in use, behind `#available`, preferring it over the sentence on a device that has it.
- Read the author's alt first everywhere, including a PDF's `/Alt`.
- Do not ship a downloaded model, any cloud path, or anything of VoiceOver's.
- Order the labels by confidence and stay silent about a picture rather than guess.

## Plan in phases

Sizes are estimates, not measurements.

1. **Evidence engine (Mac and iPhone).**
   - `PictureEvidence` and `PictureEvidenceReader`: kind, labels above a threshold, text lines, table cells, codes, saliency order; a protocol with a fake for tests, as `PDFPageTextRecognizer` has.
   - Size: about 600 lines of code, 20 to 40 KB of binary on each app; no models.
   - Tests: fake-driven tests of thresholds and ordering; a smoke test on a drawn chart, table, and QR code from a generator the test target holds.
2. **Record and reading (Mac and iPhone).**
   - `descriptions.json`, its store, the marker in content.md, the reader's "Image" line, the setting, and the braille line.
   - Size: about 1,200 lines; about 30 interface lines, 5 to 10 KB of catalog across 25 languages.
   - Tests: round trips, a re-read keeping and dropping by digest, an edit turning `machine` into `edited`, the setting's three values, cloud-only and stale files as transcripts have them.
3. **Sources (Mac and iPhone, the same parsers).**
   - EPUB, HTML in archives, DAISY, DOCX, ODT, Kindle: find pictures without alt, give the bytes and the locator; PDF figure `/Alt` and PDF regions.
   - Size: about 800 lines, spread over the parsers; no new binary weight beyond the code.
   - Tests: made EPUB, DOCX, and PDF files with and without alt, and with a tagged figure.
4. **The sheet and commands (Mac and iPhone).**
   - Describe Pictures…, Describe Pictures Again…, Delete Descriptions…, progress, Cancel, VoiceOver announcements, a library badge like Transcribed.
   - Tests as the Transcribe Audio sheet's: phases, focus, refusals while another job runs.
5. **Language model sentence (OS 26; Mac 26 and iPhone 26).**
   - Prompt, the evidence check, the language by instruction, refusal handling.
   - Size: about 300 lines and a dozen prompt lines; no model of ours.
   - Tests: a fake session; real runs only where Apple Intelligence is on, skipped elsewhere.
6. **Image caption (OS 27; Mac 27 and iPhone 27).**
   - `Attachment` with the `OCRTool` in the session; needs the 27 SDK.
   - Size: about 200 lines; no model of ours.
   - Tests: a fake session, and a run on a device on 27 with Apple Intelligence.
   - A later step: "Ask about this picture" on the same session, which is what VoiceOver's Image Explorer offers.

## Fixtures

- One generator in the test target draws the pictures of this research with Core Graphics, Core Text, and `CIFilter.qrCodeGenerator` and `code128BarcodeGenerator`: a bar chart, a flow diagram, a captioned figure, a table, a QR code, a Code 128, and a drawn scene.
- Emoji artwork is system-drawn and changes with each macOS, so it is not used in tests; a Vision result is asserted by shape (the kind is "chart", the text contains the title), never by exact labels.
- EPUB, DOCX, and PDF fixtures with and without alt text are written by code the tests hold, with these pictures inside.
- No photograph is in the repository; a test of real-photograph behaviour waits for a licensed one (question 6).

## Risks

- A wrong label spoken as fact (the dog was a squirrel): the threshold, the "computer's" mark, and the edit flow.
- Vision's labels and results change with each macOS, so goldens would break: assert shapes, and record the OS version in each record.
- The 27 API cannot be compiled or tested until Xcode 27 is used; its quality and speed are unknown until a Mac or iPhone on 27 runs it.
- This Mac has Apple Intelligence off, so the 26 sentence step is unmeasured; a Mac with it on must run the probe.
- Apple Intelligence is missing in some regions, on older devices, and for languages outside the 23; the tier fallback must be spoken plainly, not hidden.
- Guardrails may refuse a picture; the model's context is small (4,096 tokens, unchecked with images).
- Time and battery on a book with thousands of pictures: on request only, a cap, and Cancel.
- Descriptions add text that moves places and positions: a description is part of content.md and the index, so adding one is a rebuild; a re-read and Edit Text interactions need the same care transcripts got.
- Speech language for descriptions in a language the system voice does not match (question 5).
- Machine descriptions in an exported book: exports should say they are the computer's (question 7).

## Questions for you, with my answers

1. Describe on request only, or also at import? I recommend on request, with a later option, because the sentence tiers take seconds a picture.
2. Read the computer's descriptions by default? I recommend yes once a book has been described on request, always saying the computer wrote it, with the setting to read only the author's.
3. Raise the iPhone's floor to 27 for captions? I recommend no: gate with `#available`, and let 26 phones use tiers 1 and 2.
4. Ever bundle or download an open captioning model (SmolVLM, Florence-2) for Macs 14 and 15 and for Apple Intelligence off? I recommend not now; revisit after tier 3 is measured.
5. For languages outside the model's 23, speak an English description in an English voice? I recommend yes, marked, if the speech code can switch voices; otherwise read it in the book's voice.
6. May a later agent use a licensed photograph in `TestData/` (for example a public-domain one) to measure the real quality? I recommend yes, with its license in the repository, and that someone run `probefm.swift` on a Mac with Apple Intelligence on.
7. Should exports (Markdown, braille, speech) include machine descriptions? I recommend yes, with the same "described by the computer" mark and a switch.
8. Describe comic pages? I recommend no for now.
9. May a later version use Private Cloud Compute if you opt in? I recommend never, since on-device only is the promise.
10. Add "Ask about this picture" (VoiceOver's Image Explorer) on 27? I recommend yes, as a later phase, once the caption is measured.
