package com.longtailvideo.jwplayer.media
{
	import com.longtailvideo.jwplayer.events.MediaEvent;
	import com.longtailvideo.jwplayer.events.PlayerEvent;
	import com.longtailvideo.jwplayer.events.PlayerStateEvent;
	import com.longtailvideo.jwplayer.events.ProjectionEvent;
	import com.longtailvideo.jwplayer.geometry.Orientation;
	import com.longtailvideo.jwplayer.geometry.Projection;
	import com.longtailvideo.jwplayer.geometry.Projector;
	import com.longtailvideo.jwplayer.geometry.ViewProjection;
	import com.longtailvideo.jwplayer.input.UnwarpInput;
	import com.longtailvideo.jwplayer.model.PlayerConfig;
	import com.longtailvideo.jwplayer.model.PlaylistItem;
	import com.longtailvideo.jwplayer.player.PlayerState;
	
	import flash.display.Bitmap;
	import flash.display.DisplayObject;
	import flash.display.Loader;
	import flash.events.Event;
	import flash.media.Video;
	import flash.utils.*;
	
	public class UnwarpMediaProxy extends MediaProvider
	{
		private var _subProvider:MediaProvider;
		private var _timeline:Array;
		private var _projector:Projector;
		private var _currentTime:Number;
		private var _isPassthrough:Boolean;
		private var _externalProjection:Object;
		private var _externalViewProjection:Object;
		private var _inputHandler:UnwarpInput;
		/* when we receive the media, we check to see if it's a vw file.
		if it is, we don't initiate the media automatically, but rather we wait until 
		we receive the videowarp metadata. This avoids a "blip" where the file will initially
		play natively and then switch to a projected mode */
		private var _isVWM:Boolean;
		/* if the bufferfull arrives before we get the metadata, then we have to stop it and 
		later send it once we get the metadata */
		private var _needsBufferFull:Boolean;
		
		private var _viewProjection: ViewProjection;
		private var _config:PlayerConfig;
		
		private static const  _projectionFlashVars:Array = ["panmin", "panmax", "panrange", "tiltmin", "tiltmax", "tiltrange", "roi", "projectiontype"];
		private static const _viewProjectionFlashVars:Array = ["pan", "tilt", "verticalfov", "horizontalfov", "diagonalfov"];
		
		
		public function UnwarpMediaProxy(subProvider:MediaProvider)
		{
			super('unwarp');
			_subProvider = subProvider;
			_currentTime = -1;
			_isPassthrough = false;
			_externalProjection = null;
			_isVWM = false;
			_needsBufferFull = false;
		}
	
		/* This initializes any data sources */
		public override function initializeMediaProvider(cfg:PlayerConfig):void {
			super.initializeMediaProvider(cfg);
			_subProvider.initializeMediaProvider(cfg);	
			_config = cfg;
		}
		
		public override function load(itm:PlaylistItem):void 
		{
			
			setState(PlayerState.BUFFERING);
			_inputHandler = null;
			_currentTime = 0;
			_timeline = null;
			_projector = null;
			_isPassthrough = false;
			_externalProjection = null;
			_externalViewProjection = null;
			_isVWM = false;
			_needsBufferFull = false;
			

			
			this.parseFlashVars(itm);
			
			_subProvider.addGlobalListener(subProviderListener);
			_subProvider.load(itm);

		}
		
		public override function switchDestProjection():void{
			if(_projector){
				_viewProjection = new ViewProjection(_config.viewProjectionType);
				_projector.switchDestProjection(_viewProjection);
				super.resize(_width, _height);
				super.switchDestProjection();

			}
			
		}

		protected function parseFlashVars(itm:PlaylistItem):void
		{
			/*check for the itm's extension */
			if (itm.file != null && itm.file.indexOf('.')){
				var extension:String = itm.file.slice(itm.file.indexOf('.')+1);
				if (extension == "vwm") {
					_isVWM = true;
				}
			}
			
			var varList:XMLList = describeType(itm)..variable;
			
			for(var i:int; i < varList.length(); i++){
				var param:String = varList[i].@name;
				if (itm[param]){
					if (_projectionFlashVars.indexOf(param)>=0) {
						if (!_externalProjection) {
							_externalProjection = new Object();
						}
						if (param=="projectiontype") {
							_externalProjection["type"] = itm[param];
						} else {
							_externalProjection[param] = itm[param];
						}
					} else if (_viewProjectionFlashVars.indexOf(param)>=0) {
						if (!_externalViewProjection) {
							_externalViewProjection = new Object();
						}
						_externalViewProjection[param] = itm[param];
					}
				}
			}
			
		}
		
		protected function subProviderListener(e:Event):void
		{
			switch(e.type){
				case MediaEvent.JWPLAYER_MEDIA_META:
					subMetadataCallback(e);
					dispatchEvent(e);
					break;
				case MediaEvent.JWPLAYER_MEDIA_LOADED:
					subLoadedCallback(e);
					break;
				case MediaEvent.JWPLAYER_MEDIA_TIME:
					updateTime(e);
					dispatchEvent(e);
					break;
				case MediaEvent.JWPLAYER_MEDIA_BUFFER_FULL:
					if (_projector != null || _isPassthrough){
						this.dispatchEvent(e);
					} else {
						_needsBufferFull = true;
					}
					break;
 				case PlayerStateEvent.JWPLAYER_PLAYER_STATE:		
					/* The movie has stopped playing - probably because it is finished */
					var event:PlayerStateEvent = e as PlayerStateEvent;
					if (event.newstate == PlayerState.IDLE && event.oldstate == PlayerState.PLAYING) {
						this.setState(PlayerState.IDLE);
						this.stop();
						break;
					} 
				default:
					this.dispatchEvent(e);
					break;
			}
			
		}
		
		
		protected function subLoadedCallback(data:Object):void
		{
			var h:Number = getMediaWidth();
			var w:Number = getMediaHeight();
			
			if (_externalProjection) 
			{		
				var cue:Object = new Object();
				_timeline = new Array();
				cue.duration = 'always';				
				cue.projection = new Projection();
				cue.projection.guess(_externalProjection, h, w);
				_timeline.push(cue);
				
			}
			
			if (!_projector  && _timeline){
				initProjector(_timeline[0].projection);
				
				_projector.addEventListener(ProjectionEvent.VIEW_PROJECTION_SHIFT, forwardEvent);
				this.media = _projector.media;
				this.resize(_width, _height);
				
				if (_subProvider.getRawMedia() is Video)
				{
					var video:Video = _subProvider.getRawMedia() as Video;
					video.addEventListener(Event.ENTER_FRAME, enterFrame);
					/* this is the image case ... */	
				} else if (_subProvider.getRawMedia() is Loader) {
					_projector.update();
				}
				mediaRefresh();
				_inputHandler = new UnwarpInput(_projector);
				var event:ProjectionEvent = new ProjectionEvent(ProjectionEvent.VIEW_INPUT_HANDLER);
				event.data = _inputHandler;
				dispatchEvent(event);
			} else if (!_projector && !_timeline && !_isVWM) {
				_isPassthrough = true;
				this.media = _subProvider.getRawMedia();
				mediaRefresh();

			}
			
		}

		protected function mediaRefresh():void
		{
			
			
			if (this.state == PlayerState.BUFFERING) {
				if (_needsBufferFull) {
					dispatchEvent(new MediaEvent(MediaEvent.JWPLAYER_MEDIA_BUFFER_FULL));
					_needsBufferFull = false;
				}
				dispatchEvent(new MediaEvent(MediaEvent.JWPLAYER_MEDIA_LOADED));
				/*this.resize(_width, _height);*/
			} else {
				dispatchEvent(new MediaEvent(MediaEvent.JWPLAYER_MEDIA_REFRESH));
				/* if it's playing we actually have to set it to be visible */
				if (this.state == PlayerState.PLAYING) {
					this.media.visible = true;
				}
			}
			
		}
		
		protected function forwardEvent(e:Event):void
		{
			this.dispatchEvent(e);
		}
		
		protected function initProjector(projection:Projection):void
		{
			_viewProjection = new ViewProjection(_config.viewProjectionType);
			if (_externalViewProjection) {
				
				_viewProjection.setView(_externalViewProjection);
			}
			
			
			if (this.width == 0 || this.height == 0){
				/* just supply some defaults. sometimes we receive the metadata concerning the xmp before we receive the metadata concerning the width and height
				These same defaults are used by the videoProvider. */
				_width = 320;
				_height = 240;
			}
			var rawMedia:DisplayObject = _subProvider.getRawMedia()
			_projector = new Projector(rawMedia, projection, _viewProjection, _width, _height);
			
		}
		
		private function enterFrame(e:Event):void {			
			if (_isPassthrough){
				return;	
			}
			//TypeError: Error #1009: Cannot access a property or method of a null object reference.
			//0at com.longtailvideo.jwplayer.media::UnwarpMediaProxy/enterFrame()[/Users/susan/JWPano5.0Branch/src/com/longtailvideo/jwplayer/media/UnwarpMediaProxy.as:218]
			if (_projector.busy()){ 
				return;
			}
	
			updateTime(_subProvider.getTime());
			
			_projector.update();
		}
		
		/* This is called to check if we need to move a new projection on the timeline */
		protected function updateTime(currentTime:Object):void
		{
			
			if (currentTime is Event)
			{
				currentTime = currentTime.position;
			}
			
			if (_isPassthrough)
			{
				return;
			}
			

			
			if (_timeline[_currentTime].duration != 'always' && ( currentTime > _timeline[_currentTime].end || currentTime < _timeline[_currentTime].start))
			{

				for (var x:Number = 0; x < _timeline.length; x++) {
					if (_timeline[x].start < currentTime && _timeline[x].end > currentTime){
						_currentTime = x;
						_projector.switchSourceProjection(_timeline[_currentTime].projection);
						dispatchEvent(new ProjectionEvent(ProjectionEvent.SOURCE_PROJECTION_SWITCH));
					}
				}	
			}
		}
		
		/* we need to process the XMP and resize events of the video below us.
		This function intercepts those resizes and responds to them */

		protected function subMetadataCallback(data:Object):void
		{
			
			if (data.hasOwnProperty("metadata")) {
				var metadata:Object = data.metadata;
				if (metadata.hasOwnProperty('type')) {
					if (metadata.type == "xmp"){
						if (_externalProjection){
							return
						}
						try {
							parseXmp(metadata.data);
						} catch (error:Error) {
							trace("Error parsing media xmp: ", error);
						}
						if (!_projector  && _timeline){
							_isPassthrough = false;
							initProjector(_timeline[0].projection);
							_projector.addEventListener(ProjectionEvent.VIEW_PROJECTION_SHIFT, forwardEvent);
							this.media = _projector.media;
							this.resize(_width, _height);
							if (_subProvider.getRawMedia() is Video){
								var video:Video = _subProvider.getRawMedia() as Video;
								video.addEventListener(Event.ENTER_FRAME, enterFrame);
									/* this is the image case ... */	
							} else if (_subProvider.getRawMedia() is Loader) {
								_projector.update();
							}
							mediaRefresh();
							_inputHandler = new UnwarpInput(_projector);
							var event:ProjectionEvent = new ProjectionEvent(ProjectionEvent.VIEW_INPUT_HANDLER);
							event.data = _inputHandler;
							dispatchEvent(event);
						} else if (!_projector && !_timeline) {
							_isPassthrough = true;
							this.media = _subProvider.getRawMedia();
							mediaRefresh();
						}
					}
				}
				if (metadata.hasOwnProperty("width")){
					/* video size was found... so we need to change a few things */
					if (_projector && _timeline){
						/* we have to redo everything */
						var h: int = getMediaWidth();
						var w: int = getMediaHeight();
 						if (_externalProjection){
							_timeline[_currentTime].projection.guess(_externalProjection, w, h);
						}
						_projector.switchSourceProjection(_timeline[_currentTime].projection)
					}
					resize(_width, _height);
				}
			}
			
		}
	
		protected function getMediaWidth():int
		{
			

			var w:Number;
			if (_subProvider.getRawMedia() is Video){
				var mediaVideo:Video = _subProvider.getRawMedia() as Video;
				w = mediaVideo.videoHeight;
				if (w== 0)
				{
					w = mediaVideo.width;
				}
			} else if (_subProvider.getRawMedia() is Loader) {
				var mediaLoader:Loader = _subProvider.getRawMedia() as Loader;
				var mediaBitmap:Bitmap = mediaLoader as Bitmap;
				w = mediaBitmap.bitmapData.width;
			} else {		
				w = _subProvider.height;
			}
			
			return w;
			
		}
		
		protected function getMediaHeight():int
		{
			var h:Number;
			if (_subProvider.getRawMedia() is Video){
				var mediaVideo:Video = _subProvider.getRawMedia() as Video;
				h = mediaVideo.videoWidth;
				if (h == 0)
				{
					h = mediaVideo.height;
				}
			} else if (_subProvider.getRawMedia() is Loader) {
				var mediaLoader:Loader = _subProvider.getRawMedia() as Loader;
				var mediaBitmap:Bitmap = mediaLoader as Bitmap;
				h = mediaBitmap.bitmapData.height;
			} else {		
				h = _subProvider.width;
			}	
			
			return h;
		}
		
		
		protected function parseXmp(info:Object):void
		{
			if (!_externalProjection && _projector)
			{
				return;
			}
			var xmpXML:XML = new XML(info);
			var xmpDM:Namespace = new Namespace("http://ns.adobe.com/xmp/1.0/DynamicMedia/"); 
			var rdf:Namespace = new Namespace("http://www.w3.org/1999/02/22-rdf-syntax-ns#");
			var proj:Namespace = new Namespace("ns:eyesee360.com/ns/xmp_projection1/"); 
			var vw:Namespace = new Namespace("ns:eyesee360.com/ns/xmp_videowarp1/"); 
			
			var cue:Object;
			/* same projection throughout */
			if (xmpXML.rdf::RDF.rdf::Description.proj::Projection.length() >0)
			{
				cue = new Object();
				_timeline = new Array();
				cue.duration = 'always';
				cue.projection = new Projection();
				trace("Projection Data: ", xmpXML.rdf::RDF.rdf::Description.proj::Projection.toXMLString());
				cue.projection.xml(xmpXML.rdf::RDF.rdf::Description.proj::Projection[0]);
				_timeline = new Array();
				_timeline[0] = cue;
				
			} else {
				var x:Number = 0;
				_timeline = new Array();

				for each (var it:XML in xmpXML.rdf::RDF.rdf::Description.xmpDM::Tracks.rdf::Bag.rdf::li) {
						
					cue = new Object();
					var frames:Number = 1;
					var seconds:Number = 1;
					if (it.rdf::Description.@xmpDM::frameRate.length() > 0) 
					{
						/* parse the frame rate */
						var framerateString:String = it.rdf::Description.@xmpDM::frameRate;
						if (framerateString.indexOf('s')!=-1)
						{
							seconds = Number(framerateString.slice(framerateString.indexOf('s')+1));
							frames = Number(framerateString.slice(1, framerateString.indexOf('s')));
						} else {
							frames = Number(framerateString.slice(1));
						}
					}
					cue.start = (Number(it.rdf::Description.xmpDM::markers.rdf::Seq.rdf::li.@xmpDM::startTime)/frames)*seconds;
					cue.end = cue.start + ((Number(it.rdf::Description.xmpDM::markers.rdf::Seq.rdf::li.@xmpDM::duration)/frames) * seconds);
					cue.duration = cue.end - cue.start;
					cue.projection = new Projection();
					cue.projection.xml(it.rdf::Description.proj::Projection[0]);
	
					_timeline[x] = cue;
					x++;
				}
			}
			
			
			
			
		}
		
		public override function resize(width:Number, height:Number):void {
			_width = width;
			_height = height;
			
			if (!_isPassthrough && _projector){
				_projector.resize(width, height);
				if (_inputHandler){
					_inputHandler.resize();
				}
			} else {
				/*_subProvider.resize(width, height);*/
			}
			
			super.resize(width,height);
		}
	
		public override function pause():void {
			_subProvider.pause();
			super.pause();
		}
		
		
		/** Resume playback of the_item. **/
		public override function play():void {
			
			_subProvider.play();
			if (_inputHandler)
			{
				_inputHandler.resume();
				
			}
			if (_timeline){
				updateTime(_subProvider.getTime());
			}
			super.play();
		}
		
		/** Seek to a certain _position in the_item. **/
		public override function seek(pos:Number):void {
			_subProvider.seek(pos);
			if (_timeline){
				updateTime(_subProvider.getTime());
			}
			super.seek(pos);
		}
		
		
		/** Stop the image _postitionInterval. **/
		public override function stop():void {
			_subProvider.stop();
			_inputHandler.terminate();
			
			if (_subProvider.getRawMedia() is Video)
			{
				var video:Video = _subProvider.getRawMedia() as Video;
				video.removeEventListener(Event.ENTER_FRAME, enterFrame);
			}
			
			super.stop();
		}
		
		public override function getTime():Number
		{
			return _subProvider.getTime();
		}
	
		public override function getRawMedia():DisplayObject
		{
			return _projector.media;
			
		}
	
		public override function setVolume(vol:Number):void {
			_subProvider.setVolume(vol);
			super.setVolume(vol);
		}
		
	}
}