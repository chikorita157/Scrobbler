//
//  ScrobblerAppDelegate.m
//  Scrobbler
//
//  Created by Nanoha Takamachi on 10/28/11.
//  Copyright 2011 __MyCompanyName__. All rights reserved.
//

#import "ScrobblerAppDelegate.h"
#import "MPTidbits.h"
#import "EMKeychainItem.h"
#import "EMKeychainProxy.h"
#import "SYUIController.h"

@implementation ScrobblerAppDelegate

#pragma mark Initializers
+ (void)initialize
{
	NSDictionary *defaults = [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithBool:NO], @"LastFMConfigured", @"", @"LastFMUsername", nil];
	[[NSUserDefaults standardUserDefaults] registerDefaults:defaults];
}
- (id)init
{
	if (self = [super init])
	{
		recentTracks = [[NSMutableArray alloc] init];
		wasPlaying = NO;
	}
	return self;
}

#pragma mark Deallocator
- (void)dealloc
{
	[recentTracks release];
	[super dealloc];
}

#pragma mark Application delegate methods
- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
	// setup for the API
	// We'll use this variable for when we need to switch back and
	// forth between the web browser
	authorizationPending = NO;
	
	// First, let's setup the web service object
	// You can obtain the API key and shared secret on your API info page
	//  - http://www.last.fm/api/account
	
	LFWebService *lastfm = [LFWebService sharedWebService];
	[lastfm setDelegate:self];
	[lastfm setAPIKey:@"dc852ce9f5314e44580975a3450537ea"];
	[lastfm setSharedSecret:@"f09882b88a33baa4db0371edfbb502af"];
	
	// We'll also set our client ID for scrobbling
	// You can obtain one of these by contacting Last.fm
	//  - http://www.last.fm/api/submissions#1.1
	[lastfm setClientID:@"tst"];
    [lastfm setClientVersion:@"1.0"];
	//[lastfm setClientVersion:[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"]];
	
	// In order to run, we need a valid session key
	// First, we'll check to see if we have one. If we do,
	// we'll set it, then test it. Otherwise, we'll wait for
	// someone to click the "Connect" button.
	[self connectWithStoredCredentials];
	
	// register for our iTunes notifications
	[[NSDistributedNotificationCenter defaultCenter] addObserver:self selector:@selector(playerInfoChanged:) name:@"com.apple.iTunes.playerInfo" object:nil];
    
    //Create the NSStatusBar and set its length
    statusItem = [[[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength] retain];
    
    //Used to detect where our files are
    NSBundle *bundle = [NSBundle mainBundle];
    
    //Allocates and loads the images into the application which will be used for our NSStatusItem
    statusImage = [[NSImage alloc] initWithContentsOfFile:[bundle pathForResource:@"love" ofType:@"png"]];
    statusHighlightImage = [[NSImage alloc] initWithContentsOfFile:[bundle pathForResource:@"love" ofType:@"png"]];
    
    //Sets the images in our NSStatusItem
    [statusItem setImage:statusImage];
    [statusItem setAlternateImage:statusHighlightImage];
    
    //Tells the NSStatusItem what menu to load
    [statusItem setMenu:statusMenu];
    //Sets the tooptip for our item
    [statusItem setToolTip:@"Scrobbler"];
    //Enables highlighting
    [statusItem setHighlightMode:YES];
    //Set Scrobble Endabled
    ScrrobleState = TRUE;
}
- (void)applicationDidBecomeActive:(NSNotification *)aNotification
{
	// If we have a pending authorization, this is our
	// cue to start trying to validate it, since the user likely
	// just switched back from the browser window
	if (authorizationPending)
	{
		authorizationPending = NO;
		[self completeAuthorization:nil];
	}
}
- (BOOL)applicationOpenUntitledFile:(NSApplication *)theApplication
{
	[mainWindow makeKeyAndOrderFront:self];
	return YES;
}

#pragma mark Connection methods
- (IBAction)connectWithLastFM:(id)sender
{
	// This means we're going to force establish a new Last.fm session
	[[LFWebService sharedWebService] establishNewSession];
	
	// Adjust the UI to show status
	[ui showPreAuthMessage];
}
- (IBAction)disconnectFromLastFM:(id)sender
{
	// We need to get the username
	NSString *theUser = [[NSUserDefaults standardUserDefaults] objectForKey:@"LastFMUsername"];
	
	// We need to delete the user default information
	[[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"LastFMConfigured"];
	[[NSUserDefaults standardUserDefaults] removeObjectForKey:@"LastFMUsername"];
	
	// And clear the Keychain info
	NSString *keychainService = [NSString stringWithFormat:@"Last.fm (%@)", [[NSBundle mainBundle] bundleIdentifier]];
	EMGenericKeychainItem *keyItem = [[EMKeychainProxy sharedProxy] genericKeychainItemForService:keychainService withUsername:theUser];
	if (keyItem)
		[keyItem setPassword:@""];
	
	// Finally, clear out the web service...
	LFWebService *lastfm = [LFWebService sharedWebService];
	[lastfm setSessionUser:nil];
	[lastfm setSessionKey:nil];
	
	// ... and update the UI
	[ui showConnectMessage];
}
- (void)connectWithStoredCredentials
{
	// we have stored credentials, so we'll grab the user from the defaults,
	// then grab the session key from the keychain...
	
	if ([[NSUserDefaults standardUserDefaults] boolForKey:@"LastFMConfigured"])
	{
		NSString *theUser = [[NSUserDefaults standardUserDefaults] objectForKey:@"LastFMUsername"];
		
		NSString *keychainService = [NSString stringWithFormat:@"Last.fm (%@)", [[NSBundle mainBundle] bundleIdentifier]];
		EMGenericKeychainItem *keyItem = [[EMKeychainProxy sharedProxy] genericKeychainItemForService:keychainService withUsername:theUser];
		if (keyItem)
		{
			// we'll set both the user and session key in the web service
			LFWebService *lastfm = [LFWebService sharedWebService];
			[lastfm setSessionUser:theUser];
			[lastfm setSessionKey:[keyItem password]];
			
			// and then attempt to validate the credentials
			[lastfm validateSessionCredentials];
			
			// Adjust the UI
			[ui showValidatingMessage];
		}
	}
}
- (void)completeAuthorization:(NSNotification *)theNotification
{
	// And now we finish authorization
	[[LFWebService sharedWebService] finishSessionAuthorization];
}

#pragma mark Web service delegate methods
- (void)sessionNeedsAuthorizationViaURL:(NSURL *)theURL
{
	// OK, so the first stage is done; we'll update the
	// UI to match the current status,
	// then open up the web browser to have the user allow our demo app
	// access
	[ui showWaitingMessage];
	
	[[NSWorkspace sharedWorkspace] openURL:theURL];
	authorizationPending = YES;
}
- (void)sessionAuthorizationStillPending
{
	// We tried to authorize the session, but the user
	// isn't done in the web browser yet. Wait 5 seconds,
	// then try again.
	
	[NSTimer scheduledTimerWithTimeInterval:5.0 target:self selector:@selector(completeAuthorization:) userInfo:nil repeats:NO];
}
- (void)sessionAuthorizationFailed
{
	// We failed. Epically.
	[ui showConnectMessage];
}
- (void)sessionCreatedWithKey:(NSString *)theKey user:(NSString *)theUser
{
	// The session key will be valid for future uses -- it never
	// expires unless explicitly revoked by the Last.fm user.
	// Therefore, we can store the user as a default, and then store
	// the key in the Keychain for future use.
	
	[[NSUserDefaults standardUserDefaults] setObject:theUser forKey:@"LastFMUsername"];
	[[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"LastFMConfigured"];
	
	NSString *keychainService = [NSString stringWithFormat:@"Last.fm (%@)", [[NSBundle mainBundle] bundleIdentifier]];
	EMGenericKeychainItem *keyItem = [[EMKeychainProxy sharedProxy] genericKeychainItemForService:keychainService withUsername:theUser];
	if (keyItem)
		[keyItem setPassword:theKey];
	else
		[[EMKeychainProxy sharedProxy] addGenericKeychainItemForService:keychainService withUsername:theUser password:theKey];
	
	// Hooray! we're up and running
	[ui showConnectedWithUser:theUser];
}

- (void)sessionValidatedForUser:(NSString *)theUser
{
	// Hooray! we're up and running
	[ui showConnectedWithUser:theUser];
}
- (void)sessionInvalidForUser:(NSString *)theUser
{
	// We failed. Epically.
	[ui showConnectMessage];
}
- (void)sessionKeyRevoked:(NSString *)theKey forUser:(NSString *)theUser
{
	// The key was revoked, so we disconnect from Last.fm permanently
	[self disconnectFromLastFM:self];
}

- (void)scrobblerClient:(NSString *)theClientID bannedForVersion:(NSString *)theClientVersion
{
	NSLog(@"Error: client banned (%@ - %@)", theClientID, theClientVersion);
}

- (void)scrobbleSucceededForTrack:(LFTrack *)theTrack
{
	NSString *tname = [NSString stringWithFormat:@"%@ (%@)", [theTrack title], [theTrack artist]];
	[recentTracks insertObject:tname atIndex:0];
	[trackTableView reloadData];
}
- (void)scrobbleFailedForTrack:(LFTrack *)theTrack error:(NSError *)theError willRetry:(BOOL)willRetry
{
	NSLog(@"Scrobble failed: %@ (%@) - %@", [theTrack title], [theTrack artist], [theError localizedDescription]);
}


#pragma mark Tracking methods
- (void)playerInfoChanged:(NSNotification *)theNotification
{
	NSDictionary *info = [theNotification userInfo];
	
	if ([[info objectForKey:@"Player State"] isEqualToString:@"Stopped"])
	{
		// Scrobble if it's necessary
		if (currentTrack)
		{
            if (ScrrobleState == TRUE) {
			[currentTrack stop];
            }
			[currentTrack release];
			currentTrack = nil;
			wasPlaying = NO;
		}
		[ui nothingPlaying];
		return;
	}
	
	// check persistentID
	NSUInteger theID = [(NSNumber *)[info objectForKey:@"PersistentID"] unsignedIntegerValue];
	if (currentTrackID != theID)
	{
		// Scrobble if it's necessary
		if (currentTrack)
		{
			if (ScrrobleState == TRUE) {
                [currentTrack stop];
            }
			[currentTrack release];
			currentTrack = nil;
			wasPlaying = NO;
		}
		
		// the track changed
		if (![info containsKey:@"Name"] || ![info containsKey:@"Artist"])
		{
			[ui unusableTrack];
			return;
		}
		
		NSString *trackName = [info objectForKey:@"Name"];
		NSString *trackArtist = [info objectForKey:@"Artist"];
		CGFloat totalTime = [(NSNumber *)[info objectForKey:@"Total Time"] floatValue] / 1000.0;
		if (ScrrobleState == TRUE) {
		LFTrack *theTrack = [LFTrack trackWithTitle:trackName artist:trackArtist duration:totalTime];
		if ([info containsKey:@"Album"])
			[theTrack setAlbum:[info objectForKey:@"Album"]];
		if ([info containsKey:@"Track Number"])
			[theTrack setAlbumPosition:[(NSNumber *)[info objectForKey:@"Track Number"] unsignedIntegerValue]];
        currentTrack = [theTrack retain];
        currentTrackID = theID;
		}
		NSString *subline = ([info containsKey:@"Album"]) ? [NSString stringWithFormat:@"%@ - %@", trackArtist, [info objectForKey:@"Album"]] : trackArtist;
		[ui displayTrack:trackName subline:subline];
		

	}
	
	if ([[info objectForKey:@"Player State"] isEqualToString:@"Playing"] && !wasPlaying)
	{
		[currentTrack play];
		wasPlaying = YES;
	}
	if ([[info objectForKey:@"Player State"] isEqualToString:@"Paused"] && wasPlaying)
	{
		[currentTrack pause];
		wasPlaying = NO;
	}
}
- (IBAction)loveTrack:(id)sender
{
	if (currentTrack)
		[currentTrack love];
}
- (IBAction)banTrack:(id)sender
{
	if (currentTrack)
		[currentTrack ban];
}

#pragma mark Table data source methods
- (NSInteger)numberOfRowsInTableView:(NSTableView *)aTableView
{
	return [recentTracks count];
}
- (id)tableView:(NSTableView *)aTableView objectValueForTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex
{
	return [recentTracks objectAtIndex:rowIndex];
}

- (IBAction)togglescrobbling:(id)sender {
		if (ScrrobleState == TRUE) {
			[ToggleScrobbling setTitle:@"Enable Scrobbling"];
            [Scrobblerstatus setStringValue:@"Scrobbling is disabled."];
			//Set Scrobbling State to true
			ScrrobleState = FALSE;
		}
		else {
			[ToggleScrobbling setTitle:@"Disable Scrobbling"];
            [Scrobblerstatus setStringValue:@"Scrobbling is enabled."];
			//Set Scrobbling State to false
			ScrrobleState = TRUE;
		}
	
}


@end
