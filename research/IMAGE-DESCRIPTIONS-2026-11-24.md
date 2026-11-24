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
- On 27, `Attachment` carries a `CGImage`, a `CIImage`, a pixel buffer, or an image file; `Attachment` and `ImageAttachmentContent` both say macOS and iOS 27.0.
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

