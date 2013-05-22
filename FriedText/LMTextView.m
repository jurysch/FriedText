//
//  LMTextField.m
//  TextFieldAutocompletion
//
//  Created by Micha Mazaheri on 12/6/12.
//  Copyright (c) 2012 Lucky Marmot. All rights reserved.
//

#import "LMTextView.h"
#import "LMTextField.h"

#import "LMCompletionView.h"
#import "LMCompletionTableView.h"

#import <QuartzCore/QuartzCore.h>

#import "NSView+CocoaExtensions.h"

#import "jsmn.h"

#import "NSArray+KeyPath.h"

#import "NSMutableAttributedString+CocoaExtensions.h"

#import "LMTokenAttachmentCell.h"
#import "LMTextAttachmentCell.h"

#import "LMFriedTextDefaultColors.h"

/* Pasteboard Constant Values:
 * NSPasteboardTypeRTFD: com.apple.flat-rtfd
 * kUTTypeFlatRTFD: com.apple.flat-rtfd
 * NSRTFDPboardType: NeXT RTFD pasteboard type
 */

#warning Make a smart system to force users to allow rich text if using tokens, while blocking rich text input if needed

@interface LMTextView () {
	NSRect _oldBounds;
}

@property (strong, nonatomic) NSTimer* timer;

@property (strong, nonatomic, readwrite) NSMutableArray* textAttachmentCellClasses;

@end



@implementation LMTextView

#pragma mark - Initializers / Setup

- (void)_setup
{
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(textDidChange:) name:NSTextDidChangeNotification object:self];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(boundsDidChange:) name:NSViewBoundsDidChangeNotification object:self.enclosingScrollView.contentView];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(textStorageDidProcessEditing:) name:NSTextStorageDidProcessEditingNotification object:self.enclosingScrollView.contentView];
	
	NSColor* baseColor = [NSColor colorWithCalibratedRed:93.f/255.f green:72.f/255.f blue:55.f/255.f alpha:1.f];
	[self setTextColor:baseColor];
	
	self.useTemporaryAttributesForSyntaxHighlight = YES;
}

- (id)initWithCoder:(NSCoder *)aDecoder
{
	self = [super initWithCoder:aDecoder];
	if (self) {
		[self _setup];
	}
	return self;
}

- (id)init
{
	self = [super init];
	if (self) {
		[self _setup];
	}
	return self;
}

- (void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Accessors

- (NSDictionary *)textAttributes
{
	return @{
		  NSFontAttributeName:[self font] ?: [NSFont systemFontOfSize:[NSFont systemFontSize]],
	NSForegroundColorAttributeName:[self textColor] ?: [NSColor blackColor],
	};
}

- (BOOL)setString:(NSString *)string isUserInitiated:(BOOL)isUserInitiated
{
	BOOL shouldSet = YES;
	
	if (isUserInitiated) {
		shouldSet = [self shouldChangeTextInRange:NSMakeRange(0, [[self string] length]) replacementString:string];
	}
	
	if (shouldSet) {
		[self setString:string];
		[self didChangeText];
	}
	
	return shouldSet;
}

- (void)setParser:(id<LMTextParser>)parser
{
	[self willChangeValueForKey:@"parser"];
	_parser = parser;
	__unsafe_unretained LMTextView* textView = self;
	[_parser setStringBlock:^NSString *{
		return [textView string];
	}];
	[_parser invalidateString];
	[self didChangeValueForKey:@"parser"];
}

+ (NSArray*)defaultTextAttachmentCellClasses
{
	return [NSArray arrayWithObjects:
			[NSTextAttachmentCell class],
			[LMTokenAttachmentCell class],
			nil];
}

- (NSMutableArray *)textAttachmentCellClasses
{
	if (_textAttachmentCellClasses == nil) {
		_textAttachmentCellClasses = [NSMutableArray arrayWithArray:[[self class] defaultTextAttachmentCellClasses]];
	}
	return _textAttachmentCellClasses;
}

#pragma mark - Observers / View Events

- (BOOL)becomeFirstResponder
{
	[self highlightSyntax:nil];
	return [super becomeFirstResponder];
}

- (void)textStorageDidProcessEditing:(NSNotification*)notification
{
	[self.parser invalidateString];
}

- (void)boundsDidChange:(NSNotification*)notification
{
	NSAssert([[NSThread currentThread] isMainThread], @"Not main thread");

	if (_optimizeHighlightingOnScrolling) {
		if (self.timer != nil) {
			[self.timer invalidate];
			self.timer = nil;
		}
		self.timer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(highlightSyntax:) userInfo:@(1) repeats:NO];
	}
	else {
		[self highlightSyntax:nil];
	}
}

- (void)textDidChange:(NSNotification *)notification
{
	if (_optimizeHighlightingOnEditing) {
		if (self.timer != nil) {
			[self.timer invalidate];
			self.timer = nil;
		}
		self.timer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(highlightSyntax:) userInfo:@(1) repeats:NO];
	}
	else {
		[self highlightSyntax:nil];
	}
}

#pragma mark - Pasteboard

- (NSString *)preferredPasteboardTypeFromArray:(NSArray *)availableTypes restrictedToTypesFromArray:(NSArray *)allowedTypes
{
	NSArray* types;
	if (allowedTypes) {
		NSMutableSet* set = [NSMutableSet setWithArray:availableTypes];
		[set intersectSet:[NSSet setWithArray:allowedTypes]];
		types = [set allObjects];
	}
	else {
		types = availableTypes;
	}
	
	NSArray* preferredTypes = nil;
	if ([self.delegate respondsToSelector:@selector(preferredPasteboardTypesForTextView:)]) {
		preferredTypes = [(id<LMTextViewDelegate>)self.delegate preferredPasteboardTypesForTextView:self];
	}
	preferredTypes = [(preferredTypes ?: @[]) arrayByAddingObjectsFromArray:@[NSPasteboardTypeRTFD, NSRTFDPboardType]];
	
	for (NSString* type in preferredTypes) {
		if ([types containsObject:type]) {
			return type;
		}
	}
	
	return [super preferredPasteboardTypeFromArray:availableTypes restrictedToTypesFromArray:allowedTypes];
}

- (BOOL)readSelectionFromPasteboard:(NSPasteboard *)pboard type:(NSString *)type
{
	// Hack: We override the type since there is a bug when drag-and-dropping files
	type = [self preferredPasteboardTypeFromArray:[pboard types] restrictedToTypesFromArray:nil];
	
	NSAttributedString* attributedString = nil;
	
	// Try to get an attributed string from the delegate
	if ([self.delegate respondsToSelector:@selector(textView:attributedStringFromPasteboard:type:range:)]) {
		attributedString = [(id<LMTextViewDelegate>)self.delegate textView:self attributedStringFromPasteboard:pboard type:type range:[self rangeForUserTextChange]];
	}
	
	// If not set by the delegate, try to read as NSPasteboardTypeRTFD or NSRTFDPboardType
	// Note: Even if doc says that NSRTFDPboardType should be replaced by NSPasteboardTypeRTFD, it is still used by the framework
	if (attributedString == nil &&
		([type isEqualToString:NSPasteboardTypeRTFD] || [type isEqualToString:NSRTFDPboardType])) {
		
		NSData* data = [pboard dataForType:type];
		if (data) {
			attributedString = [[NSMutableAttributedString alloc] initWithData:data options:nil documentAttributes:nil error:NULL];
		}
	}
	
	// If an attributedString is set before, insert it
	if (attributedString) {
		[attributedString enumerateAttribute:NSAttachmentAttributeName inRange:NSMakeRange(0, [attributedString length]) options:0 usingBlock:^(id value, NSRange range, BOOL *stop) {
			if (value) {
				NSTextAttachment* textAttachment = value;
				textAttachment.attachmentCell = [self textAttachmentCellForTextAttachment:textAttachment];
			}
		}];
		
		NSRange range = [self rangeForUserTextChange];
		if ([self shouldChangeTextInRange:range replacementString:[attributedString string]]) {
			[[self textStorage] replaceCharactersInRange:range withAttributedString:attributedString];
			[self didChangeText];
			
			return YES;
		}
		else {
			NSLog(@"readSelectionFromPasteboard: Text View rejected replacement by %@ at range %@", attributedString, NSStringFromRange(range));
		}
	}
	
	return [super readSelectionFromPasteboard:pboard type:type];
}

- (NSArray *)writablePasteboardTypes
{
	// Interesting experiment: without subclassing -writablePasteboardTypes, NSPasteboardTypeRTFD and NSRTFDPboardType are used only when another app supporting rich text such as TextEdit is open...
	
	NSMutableArray* writablePasteboardTypes = [[super writablePasteboardTypes] mutableCopy];
	
	if (![writablePasteboardTypes containsObject:NSPasteboardTypeRTFD]) {
		[writablePasteboardTypes addObject:NSPasteboardTypeRTFD];
	}
	if (![writablePasteboardTypes containsObject:NSRTFDPboardType]) {
		[writablePasteboardTypes addObject:NSRTFDPboardType];
	}
	
	return writablePasteboardTypes;
}

#pragma mark - Helpers

- (NSUInteger)charIndexForPoint:(NSPoint)point
{
	NSLayoutManager *layoutManager = [self layoutManager];
	NSUInteger glyphIndex = 0;
    NSRect glyphRect;
	NSTextContainer *textContainer = [self textContainer];
	
	// Convert view coordinates to container coordinates
    point.x -= [self textContainerOrigin].x;
    point.y -= [self textContainerOrigin].y;
	
	// Convert those coordinates to the nearest glyph index
    glyphIndex = [layoutManager glyphIndexForPoint:point inTextContainer:textContainer];
	
	// Check to see whether the mouse actually lies over the glyph it is nearest to
    glyphRect = [layoutManager boundingRectForGlyphRange:NSMakeRange(glyphIndex, 1) inTextContainer:textContainer];
	
	if (NSPointInRect(point, glyphRect)) {
		// Convert the glyph index to a character index
        return [layoutManager characterIndexForGlyphAtIndex:glyphIndex];
	}
	else {
		return NSNotFound;
	}
}

#pragma mark - Mouse Events

- (void)mouseMoved:(NSEvent *)theEvent {
    NSLayoutManager *layoutManager = [self layoutManager];
    
    // Remove any existing coloring.
    [layoutManager removeTemporaryAttribute:NSUnderlineStyleAttributeName forCharacterRange:NSMakeRange(0, [[self textStorage] length])];
	
	BOOL needsCursor = NO;
	
	NSUInteger charIndex = [self charIndexForPoint:[self convertPoint:[theEvent locationInWindow] fromView:nil]];
    if (charIndex != NSNotFound) {
		if (self.parser) {
			NSRange tokenRange;
			[self.parser keyPathForObjectAtRange:NSMakeRange(charIndex, 1) objectRange:&tokenRange];
			if (tokenRange.location != NSNotFound) {
				[layoutManager addTemporaryAttribute:NSUnderlineStyleAttributeName value:@(NSUnderlinePatternDot | NSUnderlineStyleSingle) forCharacterRange:tokenRange];
				
				needsCursor = YES;
			}
		}
    }
	
	if (needsCursor) {
		if ([NSCursor currentCursor] != [NSCursor pointingHandCursor] && self.changeCursorOnTokens) {
			[[NSCursor pointingHandCursor] push];
		}
	}
	else {
		[[NSCursor pointingHandCursor] pop];
	}
}

- (void)mouseDown:(NSEvent *)theEvent
{
	NSLayoutManager *layoutManager = [self layoutManager];
	NSTextContainer *textContainer = [self textContainer];
	NSUInteger charIndex = [self charIndexForPoint:[self convertPoint:[theEvent locationInWindow] fromView:nil]];
    if (charIndex != NSNotFound) {
		if ([[self.textStorage string] characterAtIndex:charIndex] == 0xFFFC) {
			
		}
		else if (self.parser) {
			NSRange tokenRange;
			NSArray* path = [self.parser keyPathForObjectAtRange:NSMakeRange(charIndex, 1) objectRange:&tokenRange];
			NSRect bounds = [layoutManager boundingRectForGlyphRange:tokenRange inTextContainer:textContainer];
			
			if (tokenRange.location != NSNotFound) {
				if ([self.delegate respondsToSelector:@selector(textView:mouseDownForTokenAtRange:withBounds:keyPath:)]) {
					[(id<LMTextViewDelegate>)self.delegate textView:self mouseDownForTokenAtRange:tokenRange withBounds:bounds keyPath:path];
				}
				return;
			}
		}
    }
	
	if ([self.delegate respondsToSelector:@selector(mouseDownOutsideTokenInTextView:)]) {
		[(id<LMTextViewDelegate>)self.delegate mouseDownOutsideTokenInTextView:self];
	}
	
	[super mouseDown:theEvent];
}

#pragma mark - Syntax Highlighting

- (void)highlightSyntax:(id)sender
{
	if ([[sender class] isSubclassOfClass:[NSTimer class]] &&
		[[(NSTimer*)sender userInfo] isEqual:@(1)]) {
		return;
	}
	
	_oldBounds = self.enclosingScrollView.contentView.bounds;
	
	NSLayoutManager *layoutManager = [self layoutManager];
	NSRange fullRange = NSMakeRange(0, [self.textStorage.string length]);
	
	NSRange characterRange;
	if ([self isFieldEditor]) {
		characterRange = fullRange;
	}
	else {
		NSRange glyphRange = [self.layoutManager glyphRangeForBoundingRect:self.enclosingScrollView.documentVisibleRect inTextContainer:self.textContainer];
		characterRange = [self.layoutManager characterRangeForGlyphRange:glyphRange actualGlyphRange:NULL];
	}
	
	NSTextStorage* textStorage = [self textStorage];
	NSMutableArray* removedAttribtues = [NSMutableArray array]; // Used to store which attributes were removed once
	
	if (!_useTemporaryAttributesForSyntaxHighlight) {
		[textStorage beginEditing];
	}
	
	// Store whether we can use the delegate to get the attribtues
	BOOL usingDelegate = [self.delegate respondsToSelector:@selector(textView:attributesForTextWithParser:tokenMask:atRange:)];
	
	[[self parser] applyAttributesInRange:characterRange withBlock:^(NSUInteger tokenTypeMask, NSRange range) {
		
		NSDictionary* attributes = nil;
		
		// Trying to get attribtues from delegate
		if (usingDelegate) {
			attributes = [(id<LMTextViewDelegate>)self.delegate textView:self attributesForTextWithParser:[self parser] tokenMask:tokenTypeMask atRange:range];
		}
		
		// If delegate wasn't implemented or returned nil, set default attributes
		if (attributes == nil) {
			NSColor* color = nil;
			switch (tokenTypeMask & LMTextParserTokenTypeMask) {
				case LMTextParserTokenTypeBoolean:
					color = LMFriedTextDefaultColorPrimitive;
					break;
				case LMTextParserTokenTypeNumber:
					color = LMFriedTextDefaultColorPrimitive;
					break;
				case LMTextParserTokenTypeString:
					color = LMFriedTextDefaultColorString;
					break;
				case LMTextParserTokenTypeOther:
					color = LMFriedTextDefaultColorPrimitive;
					break;
			}
			attributes = @{NSForegroundColorAttributeName:color};
		}
		
		// Remove attributes when used for first time
		for (NSString* attributeName in attributes) {
			// If not already removed...
			if (![removedAttribtues containsObject:attributeName]) {
				// Remove it
				if (_useTemporaryAttributesForSyntaxHighlight) {
					[layoutManager removeTemporaryAttribute:attributeName forCharacterRange:fullRange];
				}
				else {
					[textStorage removeAttribute:attributeName range:fullRange];
				}
				// Mark this attribute as removed
				[removedAttribtues addObject:attributeName];
			}
		}
		
		// Apply attribtue
		if (_useTemporaryAttributesForSyntaxHighlight) {
			[layoutManager addTemporaryAttributes:attributes forCharacterRange:range];
		}
		else {
			[textStorage addAttributes:attributes range:range];
		}
	}];
	
	if (!_useTemporaryAttributesForSyntaxHighlight) {
		[textStorage endEditing];
	}
}

#pragma mark - Text Attachments

- (id<NSTextAttachmentCell>)textAttachmentCellForTextAttachment:(NSTextAttachment *)textAttachment
{
	__block id<NSTextAttachmentCell> textAttachmentCell = nil;
	
	if (self.delegate && [self.delegate respondsToSelector:@selector(textView:textAttachmentCellForTextAttachment:)]) {
		textAttachmentCell = [(id<LMTextViewDelegate>)self.delegate textView:self textAttachmentCellForTextAttachment:textAttachment];
	}
	
	if (textAttachmentCell == nil) {
		[[self textAttachmentCellClasses] enumerateObjectsWithOptions:NSEnumerationReverse usingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
			if ([obj respondsToSelector:@selector(textAttachmentCellWithTextAttachment:)]) {
				textAttachmentCell = [(Class<LMTextAttachmentCell>)obj textAttachmentCellWithTextAttachment:textAttachment];
			}
			*stop = !!textAttachmentCell;
		}];
	}
	
	return textAttachmentCell;
}

#pragma mark - Completion

- (NSRange)rangeForUserCompletion
{
	if (self.parser) {
		NSRange range = {NSNotFound, 0};
		[self.parser keyPathForObjectAtRange:self.selectedRange objectRange:&range];
		
		if ([[self string] length] == 0 && range.location == NSNotFound) {
			range = NSMakeRange(0, 0);
		}
		
		return range;
	}
	else {
		return [super rangeForUserCompletion];
	}
}

@end
