/**
 * Copyright (c) 2010, 2012, Pecunia Project. All rights reserved.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation; version 2 of the
 * License.
 * 
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 * 
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA
 * 02110-1301  USA
 */

#import "TransfersController.h"
#import "TransactionController.h"
#import "PecuniaError.h"
#import "LogController.h"
#import "HBCIClient.h"
#import "MOAssistant.h"
#import "AmountCell.h"
#import "BankAccount.h"

#import "TransferFormularView.h"
#import "GradientButtonCell.h"

#import "GraphicsAdditions.h"
#import "AnimationHelper.h"

#import "MAAttachedWindow.h"

// Keys for details dictionary used for transfers + statements listviews.
NSString *StatementDateKey            = @"date";             // NSDate
NSString *StatementTurnoversKey       = @"turnovers";        // NSString
NSString *StatementRemoteNameKey      = @"remoteName";       // NSString
NSString *StatementPurposeKey         = @"purpose";          // NSString
NSString *StatementCategoriesKey      = @"categories";       // NSString
NSString *StatementValueKey           = @"value";            // NSDecimalNumber
NSString *StatementSaldoKey           = @"saldo";            // NSDecimalNumber
NSString *StatementCurrencyKey        = @"currency";         // NSString
NSString *StatementTransactionTextKey = @"transactionText";  // NSString
NSString *StatementIndexKey           = @"index";            // NSNumber
NSString *StatementNoteKey            = @"note";             // NSString
NSString *StatementRemoteBankNameKey  = @"remoteBankName";   // NSString
NSString *StatementColorKey           = @"color";            // NSColor
NSString *StatementRemoteAccountKey   = @"account";          // NSString
NSString *StatementRemoteBankCodeKey  = @"remoteBankCode";   // NSString
NSString *StatementRemoteIBANKey      = @"iban";             // NSString
NSString *StatementRemoteBICKey       = @"bic";              // NSString
NSString *StatementTypeKey            = @"type";             // NSNumber

NSString* const TransferPredefinedTemplateDataType = @"TransferPredefinedTemplateDataType"; // For dragging one of the "menu" template images.
NSString* const TransferDataType = @"TransferDataType"; // For dragging an existing transfer (sent or not).
extern NSString *TransferReadyForUseDataType;     // For dragging an edited transfer.
extern NSString *TransferTemplateDataType;        // For dragging one of the stored templates.

@interface CalendarWindow : MAAttachedWindow
{
}

@property (nonatomic, assign) TransfersController *controller;

@end

@implementation CalendarWindow

@synthesize controller;

- (void)cancelOperation:(id)sender
{
    [controller hideCalendarWindow];
}
@end

//--------------------------------------------------------------------------------------------------

@interface DeleteImageView : NSImageView
{    
}

@property (nonatomic, assign) TransfersController *controller;

@end

@implementation DeleteImageView

@synthesize controller;

- (void)viewDidMoveToSuperview
{
    [super viewDidMoveToSuperview];

    // Register for types that can be deleted.
    [self registerForDraggedTypes: [NSArray arrayWithObjects: TransferDataType, TransferReadyForUseDataType, nil]];
}

- (NSDragOperation)draggingEntered: (id <NSDraggingInfo>)info
{
    NSPasteboard *pasteboard = [info draggingPasteboard];
    NSString *type = [pasteboard availableTypeFromArray: [NSArray arrayWithObjects: TransferDataType, TransferReadyForUseDataType, nil]];
    if (type == nil) {
        return NSDragOperationNone;
    }

    [[NSCursor disappearingItemCursor] set];
    return NSDragOperationDelete;
}

- (void)draggingExited: (id <NSDraggingInfo>)info
{
    [[NSCursor arrowCursor] set];
}

- (BOOL)performDragOperation: (id<NSDraggingInfo>)info
{
    if ([controller concludeDropDeleteOperation: info]) {
        NSShowAnimationEffect(NSAnimationEffectPoof, [NSEvent mouseLocation], NSZeroSize, nil, nil, NULL);
        return YES;
    }
    return NO;
}

@end

//--------------------------------------------------------------------------------------------------

@interface DragImageView : NSImageView
{
@private
    BOOL canDrag;
    
}

@property (nonatomic, assign) TransfersController *controller;

@end

@implementation DragImageView

@synthesize controller;

- (void)mouseDown: (NSEvent *)theEvent
{
    // Keep track of mouse clicks in the view because mouseDragged may be called even when another
    // view was clicked on.
    canDrag = YES;
    [super mouseDown: theEvent];
}

- (void)mouseUp:(NSEvent *)theEvent
{
    [super mouseUp: theEvent];
    canDrag = NO;
}

- (void)mouseDragged: (NSEvent *)theEvent
{
    if (!canDrag) {
        [super mouseDragged: theEvent];
        return;
    }
    
    TransferType type;
    switch (self.tag) {
        case 0:
            type = TransferTypeInternal;
            break;
        case 2:
            type = TransferTypeEU;
            break;
        case 3:
            type = TransferTypeSEPA;
            break;
        case 4:
            return; // Not yet implemented.
            break;
        default:
            type = TransferTypeStandard;
            break;
    }
    
    if ([controller prepareTransferOfType: type]) {
        NSPasteboard *pasteBoard = [NSPasteboard pasteboardWithUniqueName];
        [pasteBoard setString: [NSString stringWithFormat: @"%i", type] forType: TransferPredefinedTemplateDataType];
        
        NSPoint location;
        location.x = 0;
        location.y = 0;
        
        [self dragImage: [self image]
                     at: location
                 offset: NSZeroSize
                  event: theEvent
             pasteboard: pasteBoard
                 source: self
              slideBack: YES];
    }
}

- (NSDragOperation)draggingSourceOperationMaskForLocal:(BOOL)isLocal
{
    return isLocal ? NSDragOperationCopy : NSDragOperationNone; 
}

- (BOOL)ignoreModifierKeysWhileDragging
{
    return YES;
}

- (void)draggedImage: (NSImage *)image endedAt: (NSPoint)screenPoint operation: (NSDragOperation)operation
{
    canDrag = NO;
}

@end

//--------------------------------------------------------------------------------------------------

@implementation TransferTemplateDragDestination

@synthesize controller;

- (id)initWithFrame:(NSRect)frameRect
{
    self = [super initWithFrame: frameRect];
    if (self != nil) {
        formularVisible = NO;
    }
    return self;
}

#pragma mark -
#pragma mark Drag and drop

- (NSDragOperation)draggingEntered: (id<NSDraggingInfo>)info
{
    NSPasteboard *pasteboard = [info draggingPasteboard];
    currentDragDataType = [pasteboard availableTypeFromArray: [NSArray arrayWithObjects: TransferDataType,
                                                               TransferPredefinedTemplateDataType, TransferReadyForUseDataType, nil]];
    return NSDragOperationNone;
}

- (NSDragOperation)draggingUpdated: (id<NSDraggingInfo>)info
{
    if (currentDragDataType == nil) {
        return NSDragOperationNone;
    }
    
    NSPoint location = info.draggingLocation;
    if (NSPointInRect(location, [self dropTargetFrame])) {
        // Mouse is within our drag target area.
        
        if ((currentDragDataType == TransferDataType || currentDragDataType == TransferPredefinedTemplateDataType) &&
            [controller editingInProgress]) {
            return NSDragOperationNone;
        }
        
        // User is dragging either a template or an existing transfer around.
        // The controller tells us if a transfer can be edited right now.
        if (formularVisible) {
            // We have already checked editing is possible when we come here.
            return NSDragOperationCopy;
        }
        
        // Check if we can start a new editing process.
        if ([controller prepareEditingFromDragging: info]) {
            [self showFormular];
            return NSDragOperationCopy;
        }
        return NSDragOperationNone;
    } else {
        // Mouse moving outside the drop target area. Hide the formular if the drag
        // operation was initiated outside this view.
        if (currentDragDataType != TransferReadyForUseDataType && ![controller editingInProgress]) {
            [self hideFormular];
        }
        return NSDragOperationNone;
    }
}

- (void)draggingExited: (id<NSDraggingInfo>)info
{
    // Re-show the transfer formular if we dragged it out to another view.
    // Hide the formular, however, if it was shown during a template-to-edit operation, which is
    // not yet finished.
    NSWindow *window = [[NSApplication sharedApplication] mainWindow];
    if (!formularVisible && [controller editingInProgress] && NSPointInRect([NSEvent mouseLocation], [window frame])) {
        [self showFormular];
    }
    if (formularVisible && ![controller editingInProgress]) {
        [self hideFormular];
    }
}

- (BOOL)prepareForDragOperation: (id<NSDraggingInfo>)info
{
    return YES;
}

- (BOOL)performDragOperation: (id<NSDraggingInfo>)info
{
    NSPoint location = info.draggingLocation;
    if (NSPointInRect(location, [self dropTargetFrame])) {
        if (currentDragDataType == TransferReadyForUseDataType) {
            
            // Nothing to do for this type.
            return false;
        }
        return [controller startEditingFromDragging: info];
    }
    return false;
}

- (void)concludeDragOperation: (id<NSDraggingInfo>)info
{
}

- (void)draggingEnded: (id <NSDraggingInfo>)info
{
}

- (BOOL)wantsPeriodicDraggingUpdates
{
    return NO;
}

/**
 * Returns the area in which a drop operation is accepted.
 */
- (NSRect)dropTargetFrame
{
    NSRect dragTargetFrame = self.frame;
    dragTargetFrame.size.width -= 150;
    dragTargetFrame.size.height = 350;
    dragTargetFrame.origin.x += 65;
    dragTargetFrame.origin.y += 35;
    
    return dragTargetFrame;
}

- (void)hideFormular
{
    if (formularVisible) {
        formularVisible = NO;
        [[controller.transferFormular animator] removeFromSuperview];
    }
}

- (void)showFormular
{
    if (!formularVisible) {
        formularVisible = YES;
        NSRect formularFrame = controller.transferFormular.frame;
        formularFrame.origin.x = (self.bounds.size.width - formularFrame.size.width) / 2 - 10;
        formularFrame.origin.y = 0;
        controller.transferFormular.frame = formularFrame;
        
        [[self animator] addSubview: controller.transferFormular];
    }
}

@end

//--------------------------------------------------------------------------------------------------

@interface TransfersController (private)
- (void)updateSourceAccountSelector;
- (void)prepareSourceAccountSelector: (BankAccount *)account;
- (void)updateTargetAccountSelector;
@end

@implementation TransfersController

@synthesize transferFormular;
@synthesize dropToEditRejected;

- (void)dealloc
{
	[formatter release];
    [calendarWindow release];
   
	[super dealloc];
}

- (void)awakeFromNib
{
    [[mainView window] setInitialFirstResponder: receiverComboBox];
    
    pendingTransfers.managedObjectContext = MOAssistant.assistant.context;
    pendingTransfers.filterPredicate = [NSPredicate predicateWithFormat: @"isSent = NO and changeState == %d", TransferChangeUnchanged];
    
    // We listen to selection changes in the pending transfers list.
    [pendingTransfers addObserver: self forKeyPath: @"selectionIndexes" options: 0 context: nil];
    
    // The pending transfers list listens to selection changes in the transfers listview (and vice versa).
    [pendingTransfers bind: @"selectionIndexes" toObject: pendingTransfersListView withKeyPath: @"selectedRows" options: nil];
    [pendingTransfersListView bind: @"selectedRows" toObject: pendingTransfers withKeyPath: @"selectionIndexes" options: nil];
    
    finishedTransfers.managedObjectContext = MOAssistant.assistant.context;
    finishedTransfers.filterPredicate = [NSPredicate predicateWithFormat: @"isSent = YES"];

    [transactionController setManagedObjectContext: MOAssistant.assistant.context];

	// Sort transfer list views by date (newest first).
	NSSortDescriptor *sd = [[[NSSortDescriptor alloc] initWithKey: @"date" ascending: NO] autorelease];
	NSArray *sds = [NSArray arrayWithObject: sd];
	[pendingTransfers setSortDescriptors: sds];
	[finishedTransfers setSortDescriptors: sds];
	
	[transferView setDoubleAction: @selector(transferDoubleClicked:) ];
	[transferView setTarget:self ];
	
    NSDictionary* positiveAttributes = [NSDictionary dictionaryWithObjectsAndKeys:
                                        [NSColor applicationColorForKey: @"Positive Cash"], NSForegroundColorAttributeName,
                                        nil
                                        ];
    NSDictionary* negativeAttributes = [NSDictionary dictionaryWithObjectsAndKeys:
                                        [NSColor applicationColorForKey: @"Negative Cash"], NSForegroundColorAttributeName,
                                        nil
                                        ];
    
	formatter = [[NSNumberFormatter alloc] init];
	[formatter setNumberStyle: NSNumberFormatterCurrencyStyle];
	[formatter setLocale:[NSLocale currentLocale]];
	[formatter setCurrencySymbol: @""];
    [formatter setTextAttributesForPositiveValues: positiveAttributes];
    [formatter setTextAttributesForNegativeValues: negativeAttributes];
    
    [pendingTransfersListView setCellSpacing: 0];
    [pendingTransfersListView setAllowsEmptySelection: YES];
    [pendingTransfersListView setAllowsMultipleSelection: YES];
    NSNumberFormatter* listViewFormatter = [pendingTransfersListView numberFormatter];
    [listViewFormatter setTextAttributesForPositiveValues: positiveAttributes];
    [listViewFormatter setTextAttributesForNegativeValues: negativeAttributes];

    // Actually, the values for the bound property and the key path don't matter as the listview has
    // a very clear understanding what it needs to bind to. It's just there to make the listviews
    // establish their bindings.
    pendingTransfersListView.owner = self;
    [pendingTransfersListView bind: @"dataSource" toObject: pendingTransfers withKeyPath: @"arrangedObjects" options: nil];

    finishedTransfersListView.owner = self;
    [finishedTransfersListView setCellSpacing: 0];
    [finishedTransfersListView setAllowsEmptySelection: YES];
    [finishedTransfersListView setAllowsMultipleSelection: YES];
    listViewFormatter = [finishedTransfersListView numberFormatter];
    [listViewFormatter setTextAttributesForPositiveValues: positiveAttributes];
    [listViewFormatter setTextAttributesForNegativeValues: negativeAttributes];
    
    [finishedTransfersListView bind: @"dataSource" toObject: finishedTransfers withKeyPath: @"arrangedObjects" options: nil];
    
    transferTemplateListView.owner = self;
    [transferTemplateListView bind: @"dataSource" toObject: transactionController.templateController withKeyPath: @"arrangedObjects" options: nil];
    
    rightPane.controller = self;
    [rightPane registerForDraggedTypes: [NSArray arrayWithObjects: TransferPredefinedTemplateDataType,
                                         TransferDataType, TransferReadyForUseDataType, nil]];

    executeImmediatelyRadioButton.target = self;
    executeImmediatelyRadioButton.action = @selector(executionTimeChanged:);
    executeAtDateRadioButton.target = self;
    executeAtDateRadioButton.action = @selector(executionTimeChanged:);

    transferFormular.controller = self;
    bankCode.delegate = self;
    
    transferInternalImage.controller = self;
    [transferInternalImage setFrameCenterRotation: -5];
    transferNormalImage.controller = self;
    [transferNormalImage setFrameCenterRotation: -5];
    transferEUImage.controller = self;
    [transferEUImage setFrameCenterRotation: -5];
    transferSEPAImage.controller = self;
    [transferSEPAImage setFrameCenterRotation: -5];
    transferDebitImage.controller = self;
    [transferDebitImage setFrameCenterRotation: -5];
    
    transferDeleteImage.controller = self;
}

- (NSMenuItem*)createItemForAccountSelector: (BankAccount *)account
{
    NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle: [account localName] action: nil keyEquivalent: @""] autorelease];
    item.representedObject = account;
    
    return item;
}

/**
 * Refreshes the content of the source account selector.
 * An attempt is made to keep the current selection.
 */
- (void)updateSourceAccountSelector
{
    [self prepareSourceAccountSelector: sourceAccountSelector.selectedItem.representedObject];
}

/**
 * Refreshes the content of the source account selector and selects the given account (if found).
 */
- (void)prepareSourceAccountSelector: (BankAccount *)account
{
    [sourceAccountSelector removeAllItems];
    
    NSMenu *sourceMenu = [sourceAccountSelector menu];
    
    Category *category = [Category bankRoot];
	NSSortDescriptor *sortDescriptor = [[[NSSortDescriptor alloc] initWithKey: @"localName" ascending: YES] autorelease];
	NSArray *sortDescriptors = [NSArray arrayWithObject: sortDescriptor];
    NSArray *institutes = [[category children] sortedArrayUsingDescriptors: sortDescriptors];
    
    // Convert list of accounts in their institutes branches to a flat list
    // usable by the selector.
    NSEnumerator *institutesEnumerator = [institutes objectEnumerator];
    Category *currentInstitute;
    NSInteger selectedItem = 1; // By default the first entry after the first institute entry is selected.
    while ((currentInstitute = [institutesEnumerator nextObject])) {
        if (![currentInstitute isKindOfClass: [BankAccount class]]) {
            continue;
        }
        NSMenuItem *item = [self createItemForAccountSelector: (BankAccount *)currentInstitute];
        [sourceMenu addItem: item];
        [item setEnabled: NO];

        NSArray *accounts = [[currentInstitute children] sortedArrayUsingDescriptors: sortDescriptors];
        NSEnumerator *accountEnumerator = [accounts objectEnumerator];
        Category *currentAccount;
        while ((currentAccount = [accountEnumerator nextObject])) {
            if (![currentAccount isKindOfClass: [BankAccount class]]) {
                continue;
            }
            item = [self createItemForAccountSelector: (BankAccount *)currentAccount];
            [item setEnabled: YES];
            item.indentationLevel = 1;
            [sourceMenu addItem: item];
            if (currentAccount == account)
                selectedItem = sourceMenu.numberOfItems - 1;
        }
    }
    
    if (sourceMenu.numberOfItems > 1) {
        [sourceAccountSelector selectItemAtIndex: selectedItem];
    } else {
        [sourceAccountSelector selectItemAtIndex: -1];
    }
    [self sourceAccountChanged: sourceAccountSelector];
}

/**
 * Refreshes the content of the target account selector, depending on the selected account in
 * the source selector. Since this is for internal transfers only also only siblings of the
 * selected accounts are valid.
 * An attempt is made to keep the currently selected account still selected.
 */
- (void)updateTargetAccountSelector
{
    BankAccount *currentAccount = targetAccountSelector.selectedItem.representedObject;
    BankAccount *sourceAccount = sourceAccountSelector.selectedItem.representedObject;
    
    [targetAccountSelector removeAllItems];
    
    NSMenu *targetMenu = [targetAccountSelector menu];
    
	NSSortDescriptor *sortDescriptor = [[[NSSortDescriptor alloc] initWithKey: @"localName" ascending: YES] autorelease];
	NSArray *sortDescriptors = [NSArray arrayWithObject: sortDescriptor];
    NSArray *siblingAccounts = [[sourceAccount siblings] sortedArrayUsingDescriptors: sortDescriptors];
    NSInteger selectedItem = 0;
    for (BankAccount *account in siblingAccounts) {
        NSMenuItem *item = [self createItemForAccountSelector: account];
        [item setEnabled: YES];
        item.indentationLevel = 1;
        [targetMenu addItem: item];
        if (currentAccount == account)
            selectedItem = targetMenu.numberOfItems - 1;
    }
    if (targetMenu.numberOfItems > 1) {
        [targetAccountSelector selectItemAtIndex: selectedItem];
    } else {
        [targetAccountSelector selectItemAtIndex: -1];
    }
    [self targetAccountChanged: targetAccountSelector];
}

/**
 * Prepares the transfer formular for editing a new or existing transfer.
 */
- (BOOL)prepareTransferOfType: (TransferType)type
{
    if ([transactionController editingInProgress]) {
        NSAlert *alert = [[[NSAlert alloc] init] autorelease];
        [alert setMessageText: NSLocalizedString(@"AP413", @"")];
        [alert runModal];

        return NO;
    }
    
    NSString *remoteAccountKey;
    NSString *remoteBankCodeKey;
    switch (type) {
        case TransferTypeInternal:
            [titleText setStringValue: NSLocalizedString(@"AP403", @"")];
            [receiverText setStringValue: NSLocalizedString(@"AP408", @"")];
            transferFormular.icon = [NSImage imageNamed: @"internal-transfer-icon.png"];
            remoteAccountKey = @"selection.remoteAccount";
            remoteBankCodeKey = @"selection.remoteBankCode";
            break;
        case TransferTypeStandard:
            [titleText setStringValue: NSLocalizedString(@"AP404", @"")];
            [receiverText setStringValue: NSLocalizedString(@"AP134", @"")];
            [accountText setStringValue: NSLocalizedString(@"AP401", @"")];
            [bankCodeText setStringValue: NSLocalizedString(@"AP400", @"")];
            transferFormular.icon = [NSImage imageNamed: @"standard-transfer-icon.png"];
            remoteAccountKey = @"selection.remoteAccount";
            remoteBankCodeKey = @"selection.remoteBankCode";
            break;
        case TransferTypeEU:
            [titleText setStringValue: NSLocalizedString(@"AP405", @"")];
            [receiverText setStringValue: NSLocalizedString(@"AP134", @"")];
            [accountText setStringValue: NSLocalizedString(@"AP409", @"")];
            [bankCodeText setStringValue: NSLocalizedString(@"AP410", @"")];
            transferFormular.icon = [NSImage imageNamed: @"eu-transfer-icon.png"];
            remoteAccountKey = @"selection.remoteIBAN";
            remoteBankCodeKey = @"selection.remoteBIC";
            break;
        case TransferTypeSEPA:
            [titleText setStringValue: NSLocalizedString(@"AP406", @"")];
            [receiverText setStringValue: NSLocalizedString(@"AP134", @"")];
            [accountText setStringValue: NSLocalizedString(@"AP409", @"")];
            [bankCodeText setStringValue: NSLocalizedString(@"AP410", @"")];
            transferFormular.icon = [NSImage imageNamed: @"sepa-transfer-icon.png"];
            remoteAccountKey = @"selection.remoteIBAN";
            remoteBankCodeKey = @"selection.remoteBIC";
            break;
        case TransferTypeDebit:
            [titleText setStringValue: NSLocalizedString(@"AP407", @"")];
            [receiverText setStringValue: NSLocalizedString(@"AP134", @"")];
            [accountText setStringValue: NSLocalizedString(@"AP401", @"")];
            [bankCodeText setStringValue: NSLocalizedString(@"AP400", @"")];
            transferFormular.icon = [NSImage imageNamed: @"debit-transfer-icon.png"];
            remoteAccountKey = @"selection.remoteAccount";
            remoteBankCodeKey = @"selection.remoteBankCode";
            break;
        case TransferTypeDated: // TODO: needs to go, different transfer types allow an execution date.
            return NO;
            break;
    }
    
    BOOL isInternal = (type == TransferTypeInternal);
    [targetAccountSelector setHidden: !isInternal];
    [receiverComboBox setHidden: isInternal];
    [accountText setHidden: isInternal];
    [accountNumber setHidden: isInternal];
    [bankCodeText setHidden: isInternal];
    [bankCode setHidden: isInternal];

    BOOL isEUTransfer = (type == TransferTypeEU);
    [targetCountryText setHidden: !isEUTransfer];
    [targetCountrySelector setHidden: !isEUTransfer];
    [feeText setHidden: !isEUTransfer];
    [feeSelector setHidden: !isEUTransfer];
    
    [bankDescription setHidden: type != TransferTypeStandard];
    
    if (remoteAccountKey != nil) {
        [accountNumber bind: @"value" toObject: transactionController.currentTransferController withKeyPath: remoteAccountKey options: nil];
    }
    if (remoteBankCodeKey != nil) {
        [bankCode bind: @"value" toObject: transactionController.currentTransferController withKeyPath: remoteBankCodeKey options: nil];
    }

    // TODO: adjust formatters for bank code and account number fields depending on the type.
    
    // These business transactions support termination:
    //   - SEPA company/normal single debit/transfer
    //   - SEPA consolidated company/normal debits/transfers
    //   - Standard company/normal single debit/transfer
    //   - Standard consolidated company/normal debits/transfers
    BOOL canBeTerminated = (type == TransferTypeSEPA) || (type == TransferTypeStandard) || (type == TransferTypeDebit);
    [executionText setHidden: !canBeTerminated];
    [executeImmediatelyRadioButton setHidden: !canBeTerminated];
    [executeImmediatelyText setHidden: !canBeTerminated];
    [executeAtDateRadioButton setHidden: !canBeTerminated];
    [executionDatePicker setHidden: !canBeTerminated];
    [calendarButton setHidden: !canBeTerminated];
    
    // Load the set of previously entered text for the receiver combo box.
    [receiverComboBox removeAllItems];
    NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *values = [userDefaults dictionaryForKey: @"transfers"];
    if (values != nil) {
        id previousReceivers = [values objectForKey: @"previousReceivers"];
        if ([previousReceivers isKindOfClass: [NSArray class]]) {
            [receiverComboBox addItemsWithObjectValues: previousReceivers];
        }
    }
    executeImmediatelyRadioButton.state = NSOnState;
    executeAtDateRadioButton.state = NSOffState;
    executionDatePicker.dateValue = [NSDate date];
    [executionDatePicker setEnabled: NO];
    [calendarButton setEnabled: NO];
    
    return YES;
}

#pragma mark -
#pragma mark Drag and drop

- (void)draggingStartsFor: (TransfersListView *)sender;
{
    dropToEditRejected = NO;
}

/**
 * Used to determine certain cases of drop operations.
 */
- (BOOL)canAcceptDropFor: (TransfersListView *)sender context: (id<NSDraggingInfo>)info
{
    if (sender == finishedTransfersListView) {
        // Can accept drops only from other transfers list views.
        return info.draggingSource == pendingTransfersListView;
    }
    if (sender == pendingTransfersListView) {
        NSPasteboard *pasteboard = [info draggingPasteboard];
        NSString *type = [pasteboard availableTypeFromArray: [NSArray arrayWithObjects: TransferDataType, TransferReadyForUseDataType, nil]];
        return type != nil;
    }
    return NO;
}

/**
 * Called when the user dragged something on one of the transfers listviews. The meaning depends
 * on the target.
 */
- (void)concludeDropOperation: (TransfersListView *)sender context: (id<NSDraggingInfo>)info
{
    NSPasteboard *pasteboard = [info draggingPasteboard];
    NSString *type = [pasteboard availableTypeFromArray: [NSArray arrayWithObjects: TransferDataType, TransferReadyForUseDataType, nil]];
    if (type == nil) {
        return;
    }
    
    if (type == TransferReadyForUseDataType) {
        if ([transactionController finishCurrentTransfer]) {
            [rightPane hideFormular];
        }
    } else {
        NSManagedObjectContext *context = MOAssistant.assistant.context;
        
        NSData *data = [pasteboard dataForType: type];
        NSArray *transfers = [NSKeyedUnarchiver unarchiveObjectWithData: data];
        
        for (NSURL *url in transfers) {
            NSManagedObjectID *objectId = [[context persistentStoreCoordinator] managedObjectIDForURIRepresentation: url];
            if (objectId == nil) {
                continue;
            }
            Transfer *transfer = (Transfer *)[context objectWithID: objectId];
            transfer.isSent = [NSNumber numberWithBool: (sender == finishedTransfersListView)];
        }
        
        NSError *error = nil;
        if ([context save: &error ] == NO) {
            NSAlert *alert = [NSAlert alertWithError: error];
            [alert runModal];
        }
    }
    
    // Changing the status doesn't refresh the data controllers - so trigger this manually.
    [pendingTransfers prepareContent];
    [finishedTransfers prepareContent];
}

/**
 * Called when the user drags transfers to the waste basket, which represents a delete operation.
 */
- (BOOL)concludeDropDeleteOperation: (id<NSDraggingInfo>)info
{
    NSPasteboard *pasteboard = [info draggingPasteboard];
    NSString *type = [pasteboard availableTypeFromArray: [NSArray arrayWithObjects: TransferDataType, TransferReadyForUseDataType, nil]];
    if (type == nil) {
        return NO;
    }
    
    if (dropToEditRejected) {
        // No delete operation + animation if the drop was rejected.
        return NO;
    }
    
    // If we are deleting a new transfer then silently cancel editing and remove the formular from screen.
    if ((type == TransferReadyForUseDataType) && transactionController.currentTransfer.changeState == TransferChangeNew) {
        [self cancelEditing];
        return YES;
    }
    
    
	NSError *error = nil;
	NSManagedObjectContext *context = MOAssistant.assistant.context;
	
	int res = NSRunAlertPanel(NSLocalizedString(@"AP14", @"Delete transfers"), 
                              NSLocalizedString(@"AP15", @"Entries will be deleted for good. Continue anyway?"),
                              NSLocalizedString(@"no", @"No"), 
                              NSLocalizedString(@"yes", @"Yes"), 
                              nil);
	if (res != NSAlertAlternateReturn) {
        return NO;
    }
	
    if (type == TransferReadyForUseDataType) {
        // We are throwing away the currently being edited transfer which was already placed in the
        // pending transfers queue but brought back for editing. This time the user wants it deleted.
        [rightPane hideFormular];
        Transfer *transfer = transactionController.currentTransfer;
        [self cancelEditing];
        [context deleteObject: transfer];
        return YES;
    }
    NSData *data = [pasteboard dataForType: type];
    NSArray *transfers = [NSKeyedUnarchiver unarchiveObjectWithData: data];
    
    
    for (NSURL *url in transfers) {
        NSManagedObjectID *objectId = [[context persistentStoreCoordinator] managedObjectIDForURIRepresentation: url];
        if (objectId == nil) {
            continue;
        }
        Transfer *transfer = (Transfer *)[context objectWithID: objectId];
		[context deleteObject: transfer];
	}
    
	if ([context save: &error ] == NO) {
		NSAlert *alert = [NSAlert alertWithError: error];
		[alert runModal];
	}
    
    return YES;
}

/**
 * Will be called when the user drags entries from either transfers listview or any of the templates
 * onto the work area.
 */
- (BOOL)prepareEditingFromDragging: (id<NSDraggingInfo>)info
{
    NSPasteboard *pasteboard = [info draggingPasteboard];
    NSString *type = [pasteboard availableTypeFromArray: [NSArray arrayWithObjects: TransferDataType, TransferPredefinedTemplateDataType, nil]];
    if (type == nil) {
        return NO;
    }
    
    // Dragging a template does not require any more action here.
    if (type == TransferPredefinedTemplateDataType) {
        return YES;
    }
    
	NSManagedObjectContext *context = MOAssistant.assistant.context;
    
    NSData *data = [pasteboard dataForType: type];
    NSArray *transfers = [NSKeyedUnarchiver unarchiveObjectWithData: data];
    
    if (transfers.count > 1) {
        NSAlert *alert = [[[NSAlert alloc] init] autorelease];
        [alert setMessageText: NSLocalizedString(@"AP414", @"")];
        [alert runModal];
        
        return NO;
    }
    
    NSURL *url = [transfers lastObject];
    NSManagedObjectID *objectId = [[context persistentStoreCoordinator] managedObjectIDForURIRepresentation: url];
    if (objectId == nil) {
        return NO;
    }
    Transfer *transfer = (Transfer *)[context objectWithID: objectId];
    if (![self prepareTransferOfType: [transfer.type intValue]]) {
        return NO;
    }
    
    return YES;
}

/**
 * Here we actually try to start the editing process. This method is called when the user dropped
 * a template or an existing transfer entry on the work area.
 */
- (BOOL)startEditingFromDragging: (id<NSDraggingInfo>)info
{
    if ([transactionController editingInProgress]) {
        dropToEditRejected = YES;
        NSAlert *alert = [[[NSAlert alloc] init] autorelease];
        [alert setMessageText: NSLocalizedString(@"AP413", @"")];
        [alert runModal];
        
        return NO;
    }
    
    NSPasteboard *pasteboard = [info draggingPasteboard];
    NSString *type = [pasteboard availableTypeFromArray: [NSArray arrayWithObjects: TransferDataType, TransferPredefinedTemplateDataType, nil]];
    if (type == nil) {
        return NO;
    }
    
    if (type == TransferPredefinedTemplateDataType) {
        // A new transfer from the template "menu".
        TransferType transferType = [[pasteboard stringForType: TransferPredefinedTemplateDataType] intValue];
        BOOL result = [transactionController newTransferOfType: transferType];
        if (result) {
            [self prepareSourceAccountSelector: nil];
        }
        return result;
    }

    // A previous check has been performed already to ensure only one entry was dragged.
	NSManagedObjectContext *context = MOAssistant.assistant.context;
    
    NSData *data = [pasteboard dataForType: type];
    NSArray *transfers = [NSKeyedUnarchiver unarchiveObjectWithData: data];
    NSURL *url = [transfers lastObject];
    NSManagedObjectID *objectId = [[context persistentStoreCoordinator] managedObjectIDForURIRepresentation: url];
    if (objectId == nil) {
        return NO;
    }
    Transfer *transfer = (Transfer *)[context objectWithID: objectId];
    BOOL result;
    if (transfer.isSent.intValue == 1) {
        // If this transfer was already sent then create a new transfer from this one.
        result = [transactionController newTransferFromExistingTransfer: transfer];
    } else {
        result = [transactionController editExistingTransfer: transfer];
        [pendingTransfers prepareContent];
    }
    if (result) {
        [self prepareSourceAccountSelector: transfer.account];
    }
    return result;
}

- (void)cancelEditing
{
	// Cancel an ongoing transfer creation (if there is one).
    if (transactionController.editingInProgress) {
        [transactionController cancelCurrentTransfer];

        [rightPane hideFormular];
        [pendingTransfers prepareContent]; // In case we edited an existing transfer.
    }
}

- (BOOL)editingInProgress
{
    return transactionController.editingInProgress;  
}

/**
 * Sends the given transfers out.
 */
- (void)doSendTransfers: (NSArray*)transfers
{
    // Show log output if wanted.
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    BOOL showLog = [defaults boolForKey: @"logForTransfers"];
    if (showLog) {
        LogController *logController = [LogController logController];
        [logController showWindow: self];
        [[logController window] orderFront: self];
    }
    
    BOOL sent = [[HBCIClient hbciClient] sendTransfers: transfers];
    if (sent) {
        // Save updates and refresh UI.
        NSError *error = nil;
        NSManagedObjectContext *context = MOAssistant.assistant.context;
        if (![context save: &error]) {
            NSAlert *alert = [NSAlert alertWithError:error];
            [alert runModal];
            return;
        }
    }
    [pendingTransfers prepareContent];
    [finishedTransfers prepareContent];
}

#pragma mark -
#pragma mark Actions messages

/**
 * Sends transfers from the pending transfer list. If nothing is selected then all transfers are
 * sent, otherwise only the selected ones are sent.
 */
- (IBAction)sendTransfers: (id)sender
{
    NSArray* transfers = pendingTransfers.selectedObjects;
    if (transfers == nil || transfers.count == 0) {
        transfers = pendingTransfers.arrangedObjects;
    }
    [self doSendTransfers: transfers];
}

/**
 * Places the current transfer in the queue so it can be sent.
 * Actually, the transfer is already in the queue (when it is created) but is marked
 * as being worked on, so it does not appear in the list.
 */
- (IBAction)queueTransfer: (id)sender
{
    [self storeReceiverInMRUList];
    
    if ([transactionController finishCurrentTransfer]) {
        [rightPane hideFormular];
        [pendingTransfers prepareContent];
    }
}

/**
 * Sends the transfer that is currently begin edited.
 */
- (IBAction)sendTransfer: (id)sender
{
    [self storeReceiverInMRUList];
    
    // Can never be called if editing is not in progress, but better safe than sorry.
    if ([self editingInProgress]) {
        NSArray* transfers = [NSArray arrayWithObject: transactionController.currentTransfer];
        [self doSendTransfers: transfers];
    }
}

- (IBAction)deleteTransfers: (id)sender
{
	NSError *error = nil;
	NSManagedObjectContext *context = [[MOAssistant assistant ] context ];
	
	NSArray* sel = [finishedTransfers selectedObjects ];
	if(sel == nil || [sel count ] == 0) return;
	
	int res = NSRunAlertPanel(NSLocalizedString(@"AP14", @"Delete transfers"), 
                              NSLocalizedString(@"AP15", @"Entries will be deleted for good. Continue anyway?"),
                              NSLocalizedString(@"no", @"No"), 
                              NSLocalizedString(@"yes", @"Yes"), 
                              nil);
	if (res != NSAlertAlternateReturn) return;
	
	for (Transfer* transfer in sel) {
		[context deleteObject: transfer ];
	}
	// save updates
	if([context save: &error ] == NO) {
		NSAlert *alert = [NSAlert alertWithError:error];
		[alert runModal];
		return;
	}
}

- (IBAction)changeTransfer: (id)sender
{
	NSArray* sel = [finishedTransfers selectedObjects ];
	if(sel == nil || [sel count ] != 1) return;
	
	[transactionController changeTransfer: [sel objectAtIndex:0 ] ];
}

- (IBAction)transferDoubleClicked: (id)sender
{
	int row = [sender clickedRow ];
	if(row<0) return;
	
	NSArray* sel = [finishedTransfers selectedObjects ];
	if(sel == nil || [sel count ] != 1) return;
	Transfer *transfer = (Transfer*)[sel objectAtIndex:0 ];
	if ([transfer.isSent boolValue] == NO) {
		[transactionController changeTransfer: transfer ];
	}
}

- (IBAction)showCalendar: (id)sender
{
    if (calendarWindow == nil) {
        NSPoint buttonPoint = NSMakePoint(NSMidX([sender frame]),
                                          NSMidY([sender frame]));
        buttonPoint = [transferFormular convertPoint: buttonPoint toView: nil];
        calendarWindow = (id)[[CalendarWindow alloc] initWithView: calendarView
                                                  attachedToPoint: buttonPoint
                                                         inWindow: [transferFormular window]
                                                           onSide: MAPositionTopLeft
                                                       atDistance: 20];

        [calendarWindow setBackgroundColor: [NSColor colorWithCalibratedWhite: 1 alpha: 0.9]];
        [calendarWindow setViewMargin: 0];
        [calendarWindow setBorderWidth: 0];
        [calendarWindow setCornerRadius: 10];
        [calendarWindow setHasArrow: YES];
        [calendarWindow setDrawsRoundCornerBesideArrow: YES];
        
        [calendarWindow setAlphaValue: 0];
        [[sender window] addChildWindow: calendarWindow ordered: NSWindowAbove];
        [calendarWindow fadeIn];
        [calendarWindow makeKeyWindow];
        calendarWindow.delegate = self;
        calendarWindow.controller = self;
        [calendar setDateValue: [executionDatePicker dateValue]];
    }
}

/**
 * Called from the calendarWindow.
 */
- (void)windowDidResignKey: (NSNotification *)notification
{
    [self hideCalendarWindow];
}

- (void)keyDown:(NSEvent *)theEvent
{
    [self hideCalendarWindow];
}

- (IBAction)calendarChanged: (id)sender
{
    [executionDatePicker setDateValue: [sender dateValue]];
    [self hideCalendarWindow];
}

- (IBAction)sourceAccountChanged: (id)sender
{
    if (![self editingInProgress]) {
        return;
    }
    
    BankAccount *account = [sender selectedItem].representedObject;
    [saldoText setObjectValue: [account catSum]];
    
	transactionController.currentTransfer.account = account;
    if (account.currency.length == 0) {
        transactionController.currentTransfer.currency = @"EUR";
    } else {
        transactionController.currentTransfer.currency = account.currency;
    }
    [self updateTargetAccountSelector];
}

- (IBAction)targetAccountChanged: (id)sender
{
    if (![self editingInProgress] || transactionController.currentTransfer.type.intValue != TransferTypeInternal) {
        return;
    }
    
    BankAccount *account = targetAccountSelector.selectedItem.representedObject;
    transactionController.currentTransfer.remoteName = account.owner;
    transactionController.currentTransfer.remoteAccount = account.accountNumber;
    transactionController.currentTransfer.remoteBankCode = account.bankCode;
    transactionController.currentTransfer.remoteBankName = account.bankName;

}

- (IBAction)executionTimeChanged: (id)sender
{
    if (sender == executeImmediatelyRadioButton) {
        executeAtDateRadioButton.state = NSOffState;
        [executionDatePicker setEnabled: NO ];
        [calendarButton setEnabled: NO ];
    } else {
        executeImmediatelyRadioButton.state = NSOffState;
        [executionDatePicker setEnabled: YES ];
        [calendarButton setEnabled: YES ];
    }
}

#pragma mark -
#pragma mark Other application logic

- (void)releaseCalendarWindow
{
    [[calendarButton window] removeChildWindow: calendarWindow];
    [calendarWindow orderOut: self];
    [calendarWindow release];
    calendarWindow = nil;
}

- (void)hideCalendarWindow
{
    if (calendarWindow != nil) {
        [calendarWindow fadeOut];
        
        // We need to delay the release of the calendar window
        // otherwise it will just disappear instead to fade out.
        [NSTimer scheduledTimerWithTimeInterval: .5
                                         target: self 
                                       selector: @selector(releaseCalendarWindow)
                                       userInfo: nil
                                        repeats: NO];
    }
}

/**
 * Stores the current value of the receiver edit field in the MRU list used for lookup
 * of previously entered receivers. The list is kept at no more than 15 entries and no duplicates.
 */
- (void)storeReceiverInMRUList
{
    NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *values = [userDefaults dictionaryForKey: @"transfers"];
    NSMutableDictionary *mutableValues;
    if (values == nil) {
        mutableValues = [NSMutableDictionary dictionary];
    } else {
        mutableValues = [values mutableCopy];
    }
    
    NSString *newValue = receiverComboBox.stringValue;
    id previousReceivers = [values objectForKey: @"previousReceivers"];
    NSMutableArray *mutableReceivers;
    if (![previousReceivers isKindOfClass: [NSArray class]]) {
        mutableReceivers = [NSMutableArray arrayWithObject: newValue];
    } else {
        mutableReceivers = [previousReceivers mutableCopy];
    }

    // Now remove a possible duplicate and add the new entry
    // at the top. Remove any entry beyond the first 15 entries finally.
    [mutableReceivers removeObject: newValue];
    [mutableReceivers insertObject: newValue atIndex: 0];
    if ([mutableReceivers count] > 15) {
        NSRange unwantedEntries = NSMakeRange(15, [mutableReceivers count] - 15);
        if (unwantedEntries.length > 0) {
            [mutableReceivers removeObjectsInRange: unwantedEntries];
        }
    }
    
    [mutableValues setObject: mutableReceivers forKey: @"previousReceivers"];
    [userDefaults setObject: mutableValues forKey: @"transfers"];
}

- (void)tableViewSelectionDidChange: (NSNotification *)aNotification
{
	NSDecimalNumber *sum = [NSDecimalNumber zero ];
	Transfer *transfer;
	NSArray *sel = [finishedTransfers selectedObjects ];
	NSString *currency = nil;

	for(transfer in sel) {
		if ([transfer.isSent boolValue] == NO) {
			if (transfer.value) {
				sum = [sum decimalNumberByAdding:transfer.value ];
			}
			if (currency) {
				if (![transfer.currency isEqualToString:currency ]) {
					currency = @"*";
				}
			} else currency = transfer.currency;
		}
	}
	
	if(currency) [selAmountField setStringValue: [NSString stringWithFormat: @"(%@%@ ausgewählt)", [formatter stringFromNumber:sum ], currency ] ];
	else [selAmountField setStringValue: @"" ];
}

- (void)tableView:(NSTableView *)aTableView willDisplayCell:(id)aCell forTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex
{
	if ([[aTableColumn identifier ] isEqualToString: @"value" ]) {
		NSArray *transfersArray = [finishedTransfers arrangedObjects];
		Transfer *transfer = [transfersArray objectAtIndex:rowIndex ];
		
		AmountCell *cell = (AmountCell*)aCell;
		cell.objectValue = transfer.value;
		cell.currency = transfer.currency;
	}
}	

#pragma mark -
#pragma mark Other delegate methods

- (void)controlTextDidEndEditing: (NSNotification *)aNotification
{
	NSTextField	*textField = [aNotification object];
	NSString *bankName;
	
	if (textField != bankCode) {
        return;
    }
	
	if (transactionController.currentTransfer.type.intValue == TransferTypeEU) {
		bankName = [[HBCIClient hbciClient] bankNameForBIC: [textField stringValue]
                                                 inCountry: transactionController.currentTransfer.remoteCountry];
	} else {
		bankName = [[HBCIClient hbciClient] bankNameForCode: [textField stringValue]
                                                  inCountry: transactionController.currentTransfer.remoteCountry];
 	}
	if (bankName != nil) {
        transactionController.currentTransfer.remoteBankName = bankName;
    }
}

#pragma mark -
#pragma mark KVO

- (void)observeValueForKeyPath: (NSString *)keyPath ofObject: (id)object change: (NSDictionary *)change context: (void *)context
{
    if (object == pendingTransfers) {
        if (pendingTransfers.selectedObjects.count == 0) {
            sendTransfersButton.title = NSLocalizedString(@"AP415", @"");
        } else {
            sendTransfersButton.title = NSLocalizedString(@"AP416", @"");
        }
    }
}

#pragma mark -
#pragma mark Interface functions for main window

- (NSView *)mainView
{
    return mainView;
}

- (void)prepare
{
    
}

- (void)activate
{
    [self updateSourceAccountSelector];
}

- (void)deactivate
{
    [self hideCalendarWindow];
}

-(void)terminate
{
    [self cancelEditing];
}

@end