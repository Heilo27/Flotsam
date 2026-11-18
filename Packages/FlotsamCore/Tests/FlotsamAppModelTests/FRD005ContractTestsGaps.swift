// FRD-005 8T contract tests, gap sweep, editor half (OC-5054 to OC-5059 and OC-5061 of
// .claude/oracle/frd-005-contract.json). The item editor model is the App-target source itself, driven against a real
// GRDB database, and its behavior is already pinned by exact-asserting tests in WorfItemBindingsEditorTests (stored
// state is read back through a FRESH database instance, expected values are literals). Each OC below is therefore a
// citation of the test whose assertions are the oracle's `then`, not a duplicate test.
//
// Citations:
//   OC-5054  WorfEditorKindTests `triggerOfferedExactlyForTheTextBearingKinds` (image, screenshot, file, folder, bundle
//            offer no trigger field; text, richText, link, color, phone, email do) and
//            `imageItemHasNoTriggerButSavesAHotkeyClear` (a hotkey on a non-text item is still editable and saved).
//   OC-5055  same `triggerOfferedExactlyForTheTextBearingKinds` for the six text-bearing kinds (editor offers recorder
//            and trigger field). Help line: FlotsamBaseTests/FRD005ContractTestsEditorHelp (red until TASK-463, obrien-463, merges).
//   OC-5056  WorfEditorSaveTests `clearingTheTriggerRemovesItAndDoesNotPrompt` (stored triggers == only the neighbour's).
//   OC-5057  WorfEditorSaveTests `changingATriggerLeavesOnlyTheNewOne` (stored triggers == [item: ";b"]).
//   OC-5058  WorfEditorValidationTests `unknownVariableSavesAndWarnsOnce` and `unknownVariableWarningReadsTheCatalogueText`
//            ('An unknown variable was left as plain text.'); the literal-insert half is FRD005ContractTestsVariables
//            (OC-5113) in FlotsamPasteTests.
//   OC-5059  WorfEditorValidationTests `invalidTriggerShowsTheInlineErrorAndBlocksSave` (canSave false, nothing stored).
//   OC-5061  WorfEditorSaveTests `clearingTheHotkeyKeepsTheTriggerAndDoesNotPrompt`; the registry drop is
//            FRD005ContractTestsLifecycleEditor (OC-5134) in this target.
//
// UNTESTABLE-AT-PACKAGE OC-5055 (opening half): pressing cmd-K and choosing 'Shortcut and Trigger...' from the context
//   menu open the popover from App-target views (ItemBindingsEditorView, the Library row menu); the package has no seam
//   that drives SwiftUI popovers or NSMenu actions. The model both open the same editor with is asserted by the
//   citations above.
// Real-app halves of OC-5056, 5057, 5059, 5061 (not separately UNTESTABLE; their stored-state halves are cited above): typing into TextEdit and the badge glyph on the
//   Library row need a real frontmost app and the rendered row; the stored-state halves are asserted by the citations.
