//
//  MPDocument.m
//  MacDown
//
//  Created by Tzu-ping Chung  on 6/06/2014.
//  Copyright (c) 2014 Tzu-ping Chung . All rights reserved.
//

#import "MPDocument.h"
#import <WebKit/WebKit.h>
#import <hoedown/html.h>
#import "HGMarkdownHighlighter.h"
#import "MPUtilities.h"
#import "NSString+Lookup.h"
#import "NSTextView+Autocomplete.h"
#import "MPPreferences.h"
#import "MPRenderer.h"
#import "MPExportPanelAccessoryViewController.h"


@implementation MPPreferences (Hoedown)
- (int)extensionFlags
{
    int flags = HOEDOWN_EXT_LAX_SPACING;
    if (self.extensionAutolink)
        flags |= HOEDOWN_EXT_AUTOLINK;
    if (self.extensionFencedCode)
        flags |= HOEDOWN_EXT_FENCED_CODE;
    if (self.extensionFootnotes)
        flags |= HOEDOWN_EXT_FOOTNOTES;
    if (self.extensionHighlight)
        flags |= HOEDOWN_EXT_HIGHLIGHT;
    if (!self.extensionIntraEmphasis)
        flags |= HOEDOWN_EXT_NO_INTRA_EMPHASIS;
    if (self.extensionQuote)
        flags |= HOEDOWN_EXT_QUOTE;
    if (self.extensionStrikethough)
        flags |= HOEDOWN_EXT_STRIKETHROUGH;
    if (self.extensionSuperscript)
        flags |= HOEDOWN_EXT_SUPERSCRIPT;
    if (self.extensionTables)
        flags |= HOEDOWN_EXT_TABLES;
    if (self.extensionUnderline)
        flags |= HOEDOWN_EXT_UNDERLINE;
    return flags;
}
@end


@interface MPDocument ()
    <NSTextViewDelegate, MPRendererDataSource, MPRendererDelegate>

@property (weak) IBOutlet NSSplitView *splitView;
@property (unsafe_unretained) IBOutlet NSTextView *editor;
@property (weak) IBOutlet WebView *preview;
@property (strong) HGMarkdownHighlighter *highlighter;
@property (strong) MPRenderer *renderer;
@property BOOL manualRender;
@property BOOL previewFlushDisabled;
@property BOOL isLoadingPreview;

// Store file content in initializer until nib is loaded.
@property (copy) NSString *loadedString;

@end


@implementation MPDocument

- (void)dealloc
{
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center removeObserver:self
                      name:NSTextDidChangeNotification
                    object:self.editor];
    [center removeObserver:self
                      name:NSUserDefaultsDidChangeNotification
                    object:[NSUserDefaults standardUserDefaults]];
    [center removeObserver:self
                      name:NSViewBoundsDidChangeNotification
                    object:self.editor.enclosingScrollView.contentView];
}


#pragma mark - Accessor

- (MPPreferences *)preferences
{
    return [MPPreferences sharedInstance];
}


#pragma mark - Override

- (NSString *)windowNibName
{
    return @"MPDocument";
}

- (void)windowControllerDidLoadNib:(NSWindowController *)controller
{
    [super windowControllerDidLoadNib:controller];

    // All files use their absolute path to keep their window states.
    // New files share a common autosave name so that we can get a preferred
    // window size when creating new documents.
    NSString *autosaveName = @"Markdown";
    if (self.fileURL)
        autosaveName = self.fileURL.absoluteString;
    controller.window.frameAutosaveName = autosaveName;

    self.highlighter =
        [[HGMarkdownHighlighter alloc] initWithTextView:self.editor
                                           waitInterval:0.1];
    self.renderer = [[MPRenderer alloc] init];
    self.renderer.dataSource = self;
    self.renderer.delegate = self;

    // Fix Xcode 5/Lion bug where disselecting options in IB doesn't work.
    // TODO: Can we save/set these app-wise using KVO?
    self.editor.automaticQuoteSubstitutionEnabled = NO;
    self.editor.automaticLinkDetectionEnabled = NO;
    self.editor.automaticDashSubstitutionEnabled = NO;
    [self setupEditor];

    self.preview.frameLoadDelegate = self;
    self.preview.policyDelegate = self;

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self
               selector:@selector(textDidChange:)
                   name:NSTextDidChangeNotification
                 object:self.editor];
    [center addObserver:self
               selector:@selector(userDefaultsDidChange:)
                   name:NSUserDefaultsDidChangeNotification
                 object:[NSUserDefaults standardUserDefaults]];
    [center addObserver:self
               selector:@selector(boundsDidChange:)
                   name:NSViewBoundsDidChangeNotification
                 object:self.editor.enclosingScrollView.contentView];

    if (self.loadedString)
    {
        self.editor.string = self.loadedString;
        self.loadedString = nil;
        [self.renderer parseAndRenderNow];
        [self.highlighter parseAndHighlightNow];
    }
}

+ (BOOL)autosavesInPlace
{
    return YES;
}

- (NSData *)dataOfType:(NSString *)typeName error:(NSError **)outError
{
    return [self.editor.string dataUsingEncoding:NSUTF8StringEncoding];
}

- (BOOL)readFromData:(NSData *)data ofType:(NSString *)typeName
               error:(NSError **)outError
{
    self.loadedString = [[NSString alloc] initWithData:data
                                              encoding:NSUTF8StringEncoding];
    return YES;
}

- (BOOL)prepareSavePanel:(NSSavePanel *)savePanel
{
    NSString *title = [self.editor.string titleString];
    if (title)
        savePanel.nameFieldStringValue = title;
    return [super prepareSavePanel:savePanel];
}

- (NSPrintOperation *)printOperationWithSettings:(NSDictionary *)printSettings
                                           error:(NSError *__autoreleasing *)e
{
    WebFrameView *frameView = self.preview.mainFrame.frameView;
    NSPrintInfo *printInfo = self.printInfo;
    return [frameView printOperationWithPrintInfo:printInfo];
}


#pragma mark - NSTextViewDelegate

- (BOOL)textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector
{
    if (commandSelector == @selector(insertTab:))
        return ![self textViewShouldInsertTab:textView];
    else if (commandSelector == @selector(insertNewline:))
        return ![self textViewShouldInsertNewline:textView];
    else if (commandSelector == @selector(deleteBackward:))
        return ![self textViewShouldDeleteBackward:textView];
    return NO;
}

- (BOOL)textView:(NSTextView *)textView shouldChangeTextInRange:(NSRange)range
                                              replacementString:(NSString *)str
{
    if (self.preferences.editorCompleteMatchingCharacters)
    {
        BOOL strikethrough = self.preferences.extensionStrikethough;
        if ([textView completeMatchingCharactersForTextInRange:range
                                                    withString:str
                                          strikethroughEnabled:strikethrough])
            return NO;
    }
    return YES;
}


#pragma mark - Fake NSTextViewDelegate

- (BOOL)textViewShouldInsertTab:(NSTextView *)textView
{
    if (self.preferences.editorConvertTabs)
    {
        [textView insertSpacesForTab];
        return NO;
    }
    return YES;
}

- (BOOL)textViewShouldInsertNewline:(NSTextView *)textView
{
    if ([textView insertMappedContent])
        return NO;
    if ([textView completeNextLine])
        return NO;
    return YES;
}

- (BOOL)textViewShouldDeleteBackward:(NSTextView *)textView
{
    if (self.preferences.editorCompleteMatchingCharacters)
    {
        NSUInteger location = self.editor.selectedRange.location;
        [textView deleteMatchingCharactersAround:location];
    }
    if (self.preferences.editorConvertTabs)
    {
        NSUInteger location = self.editor.selectedRange.location;
        [textView unindentForSpacesBefore:location];
    }
    return YES;
}


#pragma mark - WebFrameLoadDelegate

- (void)webView:(WebView *)sender didCommitLoadForFrame:(WebFrame *)frame
{
    if (!self.previewFlushDisabled && sender.window)
    {
        self.previewFlushDisabled = YES;
        [sender.window disableFlushWindow];
    }
}

- (void)webView:(WebView *)sender didFinishLoadForFrame:(WebFrame *)frame
{
    self.isLoadingPreview = NO;
    [[NSOperationQueue mainQueue] addOperationWithBlock:^{
        if (self.previewFlushDisabled)
        {
            [sender.window enableFlushWindow];
            self.previewFlushDisabled = NO;
        }
        [self syncScrollers];
    }];
}

- (void)webView:(WebView *)sender didFailLoadWithError:(NSError *)error
       forFrame:(WebFrame *)frame
{
    [self webView:sender didFinishLoadForFrame:frame];
}


#pragma mark - WebPolicyDelegate

- (void)webView:(WebView *)webView
                decidePolicyForNavigationAction:(NSDictionary *)information
        request:(NSURLRequest *)request frame:(WebFrame *)frame
                decisionListener:(id<WebPolicyDecisionListener>)listener
{
    if (self.isLoadingPreview)
    {
        // We are rendering ourselves.
        [listener use];
    }
    else
    {
        // An external location is requested. Hijack.
        [listener ignore];
        [[NSWorkspace sharedWorkspace] openURL:request.URL];
    }
}


#pragma mark - MPRendererDataSource

- (NSString *)rendererMarkdown:(MPRenderer *)renderer
{
    return self.editor.string;
}

- (NSString *)rendererHTMLTitle:(MPRenderer *)renderer
{
    NSString *name = self.fileURL.lastPathComponent;

    // TODO: Detect extensions from bundle info directly. Don't hardcode.
    if ([name hasSuffix:@".md"])
        name = [name substringToIndex:name.length - 3];
    else if ([name hasSuffix:@".markdown"])
        name = [name substringToIndex:name.length - 9];

    if (name.length)
        return name;
    return @"";
}


#pragma mark - MPRendererDelegate

- (int)rendererExtensions:(MPRenderer *)renderer
{
    return self.preferences.extensionFlags;
}

- (BOOL)rendererHasSmartyPants:(MPRenderer *)renderer
{
    return self.preferences.extensionSmartyPants;
}

- (NSString *)rendererStyleName:(MPRenderer *)renderer
{
    return self.preferences.htmlStyleName;
}

- (BOOL)rendererHasSyntaxHighlighting:(MPRenderer *)renderer
{
    return self.preferences.htmlSyntaxHighlighting;
}

- (BOOL)rendererHasMathJax:(MPRenderer *)renderer
{
    return self.preferences.htmlMathJax;
}

- (NSString *)rendererHighlightingThemeName:(MPRenderer *)renderer
{
    return self.preferences.htmlHighlightingThemeName;
}

- (void)renderer:(MPRenderer *)renderer didProduceHTMLOutput:(NSString *)html
{
    self.manualRender = self.preferences.markdownManualRender;
    NSURL *baseUrl = self.fileURL;
    if (!baseUrl)
        baseUrl = self.preferences.htmlDefaultDirectoryUrl;
    self.isLoadingPreview = YES;
    [self.preview.mainFrame loadHTMLString:html baseURL:baseUrl];
}


#pragma mark - Notification handler

- (void)textDidChange:(NSNotification *)notification
{
    if (!self.preferences.markdownManualRender)
        [self.renderer parseAndRenderLater];
}

- (void)userDefaultsDidChange:(NSNotification *)notification
{
    MPRenderer *renderer = self.renderer;

    // Force update if we're switching from manual to auto.
    if (!self.preferences.markdownManualRender && self.manualRender)
    {
        [renderer parseAndRenderLater];
    }
    else
    {
        [renderer parseLaterWithCommand:@selector(parseIfPreferencesChanged)
                      completionHandler:^{
                          [renderer render];
                      }];
        [renderer renderIfPreferencesChanged];
    }

    [self setupEditor];
}

- (void)boundsDidChange:(NSNotification *)notification
{
    [self syncScrollers];
}


#pragma mark - IBAction

- (IBAction)copyHtml:(id)sender
{
    // Dis-select things in WebView so that it's more obvious we're NOT
    // respecting the selection range.
    [self.preview setSelectedDOMRange:nil affinity:NSSelectionAffinityUpstream];

    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];
    [pasteboard writeObjects:@[self.renderer.currentHtml]];
}

- (IBAction)exportHtml:(id)sender
{
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedFileTypes = @[@"html"];
    if (self.fileURL)
    {
        NSString *fileName = self.fileURL.lastPathComponent;
        if ([fileName hasSuffix:@".md"])
            fileName = [fileName substringToIndex:(fileName.length - 3)];
        panel.nameFieldStringValue = fileName;
    }

    MPExportPanelAccessoryViewController *controller =
        [[MPExportPanelAccessoryViewController alloc] init];
    panel.accessoryView = controller.view;

    NSWindow *w = nil;
    NSArray *windowControllers = self.windowControllers;
    if (windowControllers.count)
        w = [windowControllers[0] window];
    [panel beginSheetModalForWindow:w completionHandler:^(NSInteger result) {
        if (result != NSFileHandlingPanelOKButton)
            return;
        BOOL styles = controller.stylesIncluded;
        BOOL highlighting = controller.highlightingIncluded;
        NSString *html = [self.renderer HTMLForExportWithStyles:styles
                                                   highlighting:highlighting];
        [html writeToURL:panel.URL atomically:NO encoding:NSUTF8StringEncoding
                   error:NULL];
    }];
}

- (IBAction)toggleStrong:(id)sender
{
    [self.editor toggleForMarkupPrefix:@"**" suffix:@"**"];
}

- (IBAction)toggleEmphasis:(id)sender
{
    [self.editor toggleForMarkupPrefix:@"*" suffix:@"*"];
}

- (IBAction)toggleInlineCode:(id)sender
{
    [self.editor toggleForMarkupPrefix:@"`" suffix:@"`"];
}

- (IBAction)toggleStrikethrough:(id)sender
{
    [self.editor toggleForMarkupPrefix:@"~~" suffix:@"~~"];
}

- (IBAction)toggleUnderline:(id)sender
{
    [self.editor toggleForMarkupPrefix:@"_" suffix:@"_"];
}

- (IBAction)toggleHighlight:(id)sender
{
    [self.editor toggleForMarkupPrefix:@"==" suffix:@"=="];
}

- (IBAction)toggleComment:(id)sender
{
    [self.editor toggleForMarkupPrefix:@"<!--" suffix:@"-->"];
}

- (IBAction)toggleLink:(id)sender
{
    if ([self.editor toggleForMarkupPrefix:@"[" suffix:@"]()"])
    {
        NSRange selectedRange = self.editor.selectedRange;
        NSUInteger location = selectedRange.location + selectedRange.length + 2;
        self.editor.selectedRange = NSMakeRange(location, 0);
    }
}

- (IBAction)toggleImage:(id)sender
{
    if ([self.editor toggleForMarkupPrefix:@"![" suffix:@"]()"])
    {
        NSRange selectedRange = self.editor.selectedRange;
        NSUInteger location = selectedRange.location + selectedRange.length + 2;
        self.editor.selectedRange = NSMakeRange(location, 0);
    }
}

- (IBAction)toggleUnorderedList:(id)sender
{
    [self.editor toggleBlockWithPattern:@"^[\\*\\+-] \\S" prefix:@"* "];
}

- (IBAction)toggleBlockquote:(id)sender
{
    [self.editor toggleBlockWithPattern:@"^> \\S" prefix:@"> "];
}

- (IBAction)indent:(id)sender
{
    NSString *padding = @"\t";
    if (self.preferences.editorConvertTabs)
        padding = @"    ";
    [self.editor indentSelectedLinesWithPadding:padding];
}

- (IBAction)unindent:(id)sender
{
    [self.editor unindentSelectedLines];
}

- (IBAction)insertNewParagraph:(id)sender
{
    NSRange range = self.editor.selectedRange;
    NSUInteger location = range.location;
    NSUInteger length = range.length;
    NSString *content = self.editor.string;
    NSInteger newlineBefore = [content locationOfFirstNewlineBefore:location];
    NSUInteger newlineAfter =
        [content locationOfFirstNewlineAfter:location + length - 1];

    // This is an empty line. Treat as normal return key.
    if (location == newlineBefore + 1 && location == newlineAfter)
    {
        [self.editor insertNewline:self];
        return;
    }

    // Insert two newlines after the current line, and jump to there.
    self.editor.selectedRange = NSMakeRange(newlineAfter, 0);
    [self.editor insertText:@"\n\n"];
}

- (IBAction)insertAmp:(id)sender
{
    [self.editor insertText:@"&amp;"];
}

- (IBAction)insertLt:(id)sender
{
    [self.editor insertText:@"&lt;"];
}

- (IBAction)insertGt:(id)sender
{
    [self.editor insertText:@"&gt;"];
}

- (IBAction)insertNbsp:(id)sender
{
    [self.editor insertText:@"&nbsp;"];
}

- (IBAction)insertQuot:(id)sender
{
    [self.editor insertText:@"&quot;"];
}

- (IBAction)insert39:(id)sender
{
    [self.editor insertText:@"&#39;"];
}

- (IBAction)resetSplit:(id)sender
{
    CGFloat dividerThickness = self.splitView.dividerThickness;
    CGFloat width = (self.splitView.frame.size.width - dividerThickness) / 2.0;
    NSArray *parts = self.splitView.subviews;
    NSView *left = parts[0];
    NSView *right = parts[1];

    left.frame = NSMakeRect(0.0, 0.0, width, left.frame.size.height);
    right.frame = NSMakeRect(width + dividerThickness, 0.0,
                             width, right.frame.size.height);
    [self.splitView setPosition:width ofDividerAtIndex:0];
}

- (IBAction)render:(id)sender
{
    [self.renderer parseAndRenderLater];
}

#pragma mark - Private

- (void)setupEditor
{
    [self.highlighter deactivate];
    self.editor.font = [self.preferences.editorBaseFont copy];

    int extensions = pmh_EXT_NOTES;
    if (self.preferences.extensionFootnotes)
        extensions = pmh_EXT_NONE;
    self.highlighter.extensions = extensions;

    CGFloat x = self.preferences.editorHorizontalInset;
    CGFloat y = self.preferences.editorVerticalInset;
    self.editor.textContainerInset = NSMakeSize(x, y);

    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    style.lineSpacing = self.preferences.editorLineSpacing;
    self.editor.defaultParagraphStyle = [style copy];

    self.editor.textColor = nil;
    self.editor.backgroundColor = nil;
    self.highlighter.styles = nil;
    [self.highlighter readClearTextStylesFromTextView];

    NSString *themeName = [self.preferences.editorStyleName copy];
    if (themeName.length)
    {
        NSString *path = MPThemePathForName(themeName);
        NSString *themeString = MPReadFileOfPath(path);
        [self.highlighter applyStylesFromStylesheet:themeString
                                   withErrorHandler:
            ^(NSArray *errorMessages) {
                self.preferences.editorStyleName = nil;
            }];
    }

    // Have to keep this enabled because HGMarkdownHighlighter needs them.
    NSClipView *contentView = self.editor.enclosingScrollView.contentView;
    contentView.postsBoundsChangedNotifications = YES;

    [self.highlighter activate];
}

- (void)syncScrollers
{
    if (!self.preferences.editorSyncScrolling)
        return;

    NSScrollView *editorScrollView = self.editor.enclosingScrollView;
    NSClipView *editorContentView = editorScrollView.contentView;
    NSView *editorDocumentView = editorScrollView.documentView;
    NSRect editorDocumentFrame = editorDocumentView.frame;
    NSRect editorContentBounds = editorContentView.bounds;
    CGFloat ratio = 0.0;
    if (editorDocumentFrame.size.height > editorContentBounds.size.height)
    {
        ratio = editorContentBounds.origin.y /
            (editorDocumentFrame.size.height - editorContentBounds.size.height);
    }

    NSScrollView *previewScrollView =
        self.preview.mainFrame.frameView.documentView.enclosingScrollView;
    NSClipView *previewContentView = previewScrollView.contentView;
    NSView *previewDocumentView = previewScrollView.documentView;
    NSRect previewContentBounds = previewContentView.bounds;
    previewContentBounds.origin.y =
        ratio * (previewDocumentView.frame.size.height
                 - previewContentBounds.size.height);
    previewContentView.bounds = previewContentBounds;
}

@end
