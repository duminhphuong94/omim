#import "MapViewController.hpp"
#import "EAGLView.hpp"
#import "../Settings/SettingsManager.h"

#include "RenderContext.hpp"
#include "WindowHandle.hpp"
#include "../../geometry/rect2d.hpp"
#include "../../yg/internal/opengl.hpp"
#include "../../yg/screen.hpp"
#include "../../map/drawer_yg.hpp"
#include "../../storage/storage.hpp"

typedef FrameWork<model::FeaturesFetcher, Navigator, iphone::WindowHandle> framework_t;

@implementation MapViewController

  framework_t * m_framework = NULL;
  storage::Storage m_storage;
  
- (void) OnMyPositionClicked: (id)sender
{
	if (m_locationController.active)
  {
  	[m_locationController Stop];
   	((UIBarItem *)sender).title = @"My Position";
    m_framework->DisableMyPositionAndHeading();
  }
  else
  {
		[m_locationController Start];
		m_isDirtyPosition = true;
  	((UIBarItem *)sender).title = @"Disable GPS"; 
  }
}

- (void) OnSettingsClicked: (id)sender
{
	[SettingsManager Show:self WithStorage:m_storage];
}

- (void) OnShowAllClicked: (id)sender
{
	m_framework->ShowAll();
}

- (void) dealloc
{
	[m_locationController release];
	delete m_framework;
  [super dealloc];
}

- (id) initWithCoder: (NSCoder *)coder
{
	if ((self = [super initWithCoder:coder]))
	{
		[(EAGLView*)self.view setController : self];
		
		shared_ptr<iphone::WindowHandle> windowHandle = [(EAGLView*)self.view windowHandle];
		shared_ptr<yg::ResourceManager> resourceManager = [(EAGLView*)self.view resourceManager];
		m_framework = new framework_t(windowHandle, 40);
		m_framework->Init(m_storage);
		m_StickyThreshold = 10;
		
		m_locationController = [[UserLocationController alloc] initWithDelegate:self];
		
		m_CurrentAction = NOTHING;
    m_isDirtyPosition = false;
		
		// initialize with currently active screen orientation
    [self didRotateFromInterfaceOrientation: self.interfaceOrientation];
    
		m_framework->initializeGL([(EAGLView*)self.view renderContext], resourceManager);		
		
		// to perform a proper resize
		[(EAGLView*)self.view layoutSubviews];
    
    // restore previous screen position
    if (!m_framework->LoadState())
			m_framework->ShowAll();
	}
	
	return self;
}

- (void) OnHeading: (CLHeading*) newHeading
{
	m_framework->SetHeading(newHeading.trueHeading, newHeading.magneticHeading, newHeading.headingAccuracy);
}

- (void) OnLocation: (m2::PointD const &) mercatorPoint 
			withConfidenceRadius: (double) confidenceRadius
			withTimestamp: (NSDate *) timestamp
{
  m_framework->SetPosition(mercatorPoint, confidenceRadius);
	
	if (m_isDirtyPosition)
	{
		m_framework->CenterViewport();
		m_isDirtyPosition = false;
	}
}

- (void) OnLocationError: (NSString *) errorDescription
{
	NSLog(@"Error: %@", errorDescription);
}

- (void)onResize:(GLint) width withHeight:(GLint) height
{	
	UIInterfaceOrientation orientation = [self interfaceOrientation];
	if ((orientation == UIInterfaceOrientationLandscapeLeft)
		||(orientation == UIInterfaceOrientationLandscapeRight))
		std::swap(width, height);
	NSLog(@"onResize: %d, %d", width, height);
	m_framework->OnSize(width, height);
}

NSInteger compareAddress(UITouch * l, UITouch * r, void * context)
{
	return l < r;
}

- (void)updatePointsFromEvent:(UIEvent*)event
{
	NSSet * allTouches = [event allTouches];
	int touchCount = [allTouches count];
	
  CGFloat scaleFactor = 1.0;
  if ([self.view respondsToSelector:@selector(contentScaleFactor)])
  	scaleFactor = self.view.contentScaleFactor;
  
	if (touchCount == 1)
	{
		CGPoint pt = [[[allTouches allObjects] objectAtIndex:0] locationInView:nil];
		m_Pt1 = m2::PointD(pt.x * scaleFactor, pt.y * scaleFactor);
	}
	else
	{
		NSArray * sortedTouches = [[allTouches allObjects] sortedArrayUsingFunction:compareAddress context:NULL];
		CGPoint pt1 = [[sortedTouches objectAtIndex:0] locationInView:nil];
		CGPoint pt2 = [[sortedTouches objectAtIndex:1] locationInView:nil];
		
		m_Pt1 = m2::PointD(pt1.x * scaleFactor, pt1.y * scaleFactor);
	  m_Pt2 = m2::PointD(pt2.x * scaleFactor, pt2.y * scaleFactor);
	}
}

- (void)stopCurrentAction
{
	switch (m_CurrentAction)
	{
		case NOTHING:
			break;
		case DRAGGING:
			m_framework->StopDrag(DragEvent(m_Pt1.x, m_Pt1.y));
			break;
		case SCALING:
			m_framework->StopScale(ScaleEvent(m_Pt1.x, m_Pt1.y, m_Pt2.x, m_Pt2.y));
			break;
	}
	m_CurrentAction = NOTHING;
}

- (void)touchesBegan:(NSSet*)touches withEvent:(UIEvent*)event
{
	[self updatePointsFromEvent:event];
	int touchCount = [[event allTouches] count];
	// NSLog(@"touchesBeg %i", touchCount);
	if (touchCount == 1)
	{
		m_framework->StartDrag(DragEvent(m_Pt1.x, m_Pt1.y));
		m_CurrentAction = DRAGGING;
	}
	else
	{
		m_framework->StartScale(ScaleEvent(m_Pt1.x, m_Pt1.y, m_Pt2.x, m_Pt2.y));
		m_CurrentAction = SCALING;
	}
	
	m_isSticking = true;
}

- (void)touchesMoved:(NSSet*)touches withEvent:(UIEvent*)event
{
	m2::PointD TempPt1 = m_Pt1;
	m2::PointD TempPt2 = m_Pt2;
	
	[self updatePointsFromEvent:event];
	
	bool needRedraw = false;

	if (m_isSticking)
	{
		if ((TempPt1.Length(m_Pt1) > m_StickyThreshold) || (TempPt2.Length(m_Pt2) > m_StickyThreshold))
			m_isSticking = false;
		else
		{
			/// Still stickying. Restoring old points and return.
			m_Pt1 = TempPt1;
			m_Pt2 = TempPt2;
			return;
		}
	}
	
	switch (m_CurrentAction)
	{
	case DRAGGING:
		m_framework->DoDrag(DragEvent(m_Pt1.x, m_Pt1.y));
		needRedraw = true;
		break;
	case SCALING:
		if ([[event allTouches] count] < 2)
			[self stopCurrentAction];
		else
		{
			m_framework->DoScale(ScaleEvent(m_Pt1.x, m_Pt1.y, m_Pt2.x, m_Pt2.y));
			needRedraw = true;
		}
		break;
	case NOTHING:
		return;
	}
}

- (void)touchesEnded:(NSSet*)touches withEvent:(UIEvent*)event
{
	[self updatePointsFromEvent:event];
	[self stopCurrentAction];
	
	if ((((UITouch*)[touches anyObject]).tapCount == 2) && ([[event allTouches] count] < 2))
		m_framework->ScaleToPoint(ScaleToPointEvent(m_Pt1.x, m_Pt1.y, 2));
}

- (void)touchesCancelled:(NSSet*)touches withEvent:(UIEvent*)event
{
	[self updatePointsFromEvent:event];
	[self stopCurrentAction];
	
	if ((((UITouch*)[touches anyObject]).tapCount == 2) && ([[event allTouches] count] < 2))
		m_framework->ScaleToPoint(ScaleToPointEvent(m_Pt1.x, m_Pt1.y, 2));
}

- (void)onPaint
{
	shared_ptr<iphone::WindowHandle> windowHandle = [(EAGLView*)self.view windowHandle];
	shared_ptr<PaintEvent> paintEvent(new PaintEvent(windowHandle->drawer()));
	m_framework->Paint(paintEvent);
}


/*
// Implement loadView to create a view hierarchy programmatically, without using a nib.
- (void)loadView {
}
*/

// Implement viewDidLoad to do additional setup after loading the view, typically from a nib.
- (void)viewDidLoad
{
  [super viewDidLoad];
}


// Override to allow orientations other than the default portrait orientation.
- (BOOL) shouldAutorotateToInterfaceOrientation: (UIInterfaceOrientation) interfaceOrientation
{
	return YES;
}

- (void)didReceiveMemoryWarning
{
  // Releases the view if it doesn't have a superview.
  [super didReceiveMemoryWarning];
	
	m_framework->MemoryWarning();
//	m_framework->Repaint();
	
	// Release any cached data, images, etc that aren't in use.
}

- (void)viewDidUnload
{
  // Release any retained subviews of the main view.
  // e.g. self.myOutlet = nil;
}

- (void) didRotateFromInterfaceOrientation: (UIInterfaceOrientation) fromInterfaceOrientation
{
	EOrientation newOrientation = EOrientation0;
	switch (self.interfaceOrientation)
  {
		case UIInterfaceOrientationPortrait: newOrientation = EOrientation0;break;
		case UIInterfaceOrientationPortraitUpsideDown: newOrientation = EOrientation180; break;
		case UIInterfaceOrientationLandscapeLeft: newOrientation = EOrientation90; break;
		case UIInterfaceOrientationLandscapeRight: newOrientation = EOrientation270; break;
  }
	m_framework->SetOrientation(newOrientation);
}

- (void) OnTerminate
{
	[self OnEnterBackground];
}

- (void) OnEnterBackground
{
	if (m_framework)
  {	// save world rect for next launch
  	m_framework->SaveState();
  }
}


@end
