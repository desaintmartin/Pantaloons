package com.longtailvideo.jwplayer.geometry
{
	import com.longtailvideo.jwplayer.events.ProjectionEvent;
	
	import flash.display.Bitmap;
	import flash.display.BitmapData;
	import flash.display.DisplayObject;
	import flash.display.IBitmapDrawable;
	import flash.display.Loader;
	import flash.display.MovieClip;
	import flash.display.Shader;
	import flash.display.ShaderJob;
	import flash.display.ShaderPrecision;
	import flash.display.Sprite;
	import flash.events.Event;
	import flash.events.EventDispatcher;
	import flash.events.ShaderEvent;
	import flash.geom.ColorTransform;
	import flash.geom.Matrix;
	import flash.geom.Point;
	import flash.geom.Rectangle;
	import flash.media.Video;
	import flash.utils.getTimer;
	import flash.display.IGraphicsData;
	
	
	public class Projector extends EventDispatcher
	{
		/* the original media we are supposed to transform */
		private var _media:DisplayObject;
		/* the source bitmap data */
		private var _sourceBitmap:BitmapData;
		/* the unwarped media */
		private var _projectedBitmap:BitmapData;
		/* the final bitmap that actually gets added to the movieclip */
		private var _projectedMedia:Bitmap;
		/* the projection we are currently transforming from*/
		private var _sourceProjection:Projection;
		/* the projection we are currently transforming to */
		private var _destProjection:ViewProjection;
	    /* the matrix we use to transform the media */
		private var _transformMatrix:Matrix;
		/* the matrix we use to crop the initial media */
		private var _clipRect:Rectangle;
		/* the internal representation of the drawable media (either a video or an image) */
		private var _drawable:IBitmapDrawable;
		/* the stage width of the item */
		private var _width:Number;
		/* the stage height of the item */
		private var _height:Number;
		/* the width used by the shader */
		private var _shaderWidth:Number;
		/* the height used by the shader */
		private var _shaderHeight:Number;
		/* the shader object */
		private var _shader:Shader;
		/* the current shader job */
		private var _shaderJob:ShaderJob;
		/*keeps track of whether or not a resize happened while a shader job was running */
		private var _needsSizeSync:Boolean;
		/* keeps track of whether or not a view projection shift happened while a shader job was running */
		private var _needsViewSync:Boolean;
		/* keeps track of whether or not we need to do a redraw */
		private var _needsRedraw:Boolean;
		/* keeps track of the time that has passed between updates */
		private var _lastFrameTime:Number;
		/* keeps track of the pan velocity - degrees/millisecond */
		private var _panVelocity:Number;
		/* keeps track of the tilt velocity - degrees/millisecond */
		private var _tiltVelocity:Number;
		/* keeps track of the zoom velocity - degrees/millisecond */
		private var _zoomVelocity:Number;
		/* the max shader width... beyond this we use bitmap scaling */
		private var _maxShaderWidth:Number;
		
		/* the kernel pbjs that actually do the unwarping */
		[Embed(source="EquirectangularToRectilinearKernel.pbj", mimeType="application/octet-stream")]
		private var EquirectangularToRectilinearKernel:Class;
		
		[Embed(source="CylindricalToRectilinearKernel.pbj", mimeType="application/octet-stream")]
		private var CylindricalToRectilinearKernel:Class;
		
		[Embed(source="EquiangularToRectilinearKernel.pbj", mimeType="application/octet-stream")]
		private var EquiangularToRectilinearKernel:Class;
		
		[Embed(source="EquirectangularToEquirectangularKernel.pbj", mimeType="application/octet-stream")]
		private var EquirectangularToEquirectangularKernel:Class;
		
		public function Projector(media:DisplayObject, sourceprojection:Projection, destprojection:ViewProjection, width:Number, height:Number)
		{
			_sourceProjection = sourceprojection;
			_destProjection = destprojection;
			_destProjection.setConstraintsFromProjection(_sourceProjection);
			_destProjection.addEventListener(ProjectionEvent.VIEW_PROJECTION_SHIFT, viewShift);
			_needsSizeSync = false;
			_needsViewSync = false;
			_needsRedraw = false;
			_media = media;
			_width = width;
			_height = height;
			_panVelocity = 0.0;
			_tiltVelocity = 0.0;
			_zoomVelocity = 0.0;
			_lastFrameTime = 0.0;
			_maxShaderWidth = 20000;
			initializeData();
		}
		
		public function switchSourceProjection(projection:Projection):void
		{
			_sourceProjection = projection;
			_destProjection.setConstraintsFromProjection(_sourceProjection);
			if (_shaderJob) {
				_shaderJob.cancel();
			} 
			initializeData();
		}
		
		public function switchDestProjection(projection:ViewProjection):void{
			_destProjection = projection;
			_destProjection.setConstraintsFromProjection(_sourceProjection);
			if (_shaderJob) {
				_shaderJob.cancel();
			} 
			resize(_width, _height);
			initShader();
		}
		
		public function viewShift(data:Object):void
		{
			/* when the view projection changes, we have to update the shader's inputs */
			syncView();

			var event2:ProjectionEvent = new ProjectionEvent(ProjectionEvent.VIEW_PROJECTION_SHIFT);
			this.dispatchEvent(event2);
			
		}
		
		protected function initializeData():void
		{
			initSource();
			syncDest();
			initShader();
			syncView();
		}
		
		/* this is called when the view projection shifts*/
		protected function updateView():void
		{
			/* this is the first time the function has been called */
			if (_lastFrameTime == 0.0) {
				_lastFrameTime = getTimer();		
				
			} else {
				_destProjection.removeEventListener(ProjectionEvent.VIEW_PROJECTION_SHIFT, viewShift);
				var currentTime:Number = getTimer();
				if (_panVelocity != 0) { 
					switch (_destProjection.type){
						case Projection.RECTILINEAR:
							_destProjection.pan  += _panVelocity * (currentTime - _lastFrameTime);
							break;
						case Projection.EQUIRECTANGULAR:
							_destProjection.pan  += _panVelocity * (currentTime - _lastFrameTime) / 100;
							break;
						default: break;
					}
				}
				if (_tiltVelocity != 0) {
					_destProjection.tilt += _tiltVelocity * (currentTime - _lastFrameTime);
				}
				if (_zoomVelocity != 0) {
					_destProjection.verticalFOV += _zoomVelocity * (currentTime - _lastFrameTime);
				}
				_lastFrameTime = currentTime;
				
				if (_panVelocity != 0 || _tiltVelocity != 0 || _zoomVelocity != 0) {
					var rectProjection:ViewProjection = _destProjection as ViewProjection;
					_shader.data.viewBounds.value = rectProjection.bounds;
					switch (_destProjection.type){
						case Projection.RECTILINEAR:
							_shader.data.rotationMatrix.value =
									[
										rectProjection.orientation.rawData[0], rectProjection.orientation.rawData[1], rectProjection.orientation.rawData[2],
										rectProjection.orientation.rawData[4], rectProjection.orientation.rawData[5], rectProjection.orientation.rawData[6],
										rectProjection.orientation.rawData[8], rectProjection.orientation.rawData[9], rectProjection.orientation.rawData[10]
									];
							break;
						case Projection.EQUIRECTANGULAR:
							_shader.data.rotationMatrix.value = [rectProjection.orientation.pan];
							break;
						
						default: break;
					}
					 
				}						
				_destProjection.addEventListener(ProjectionEvent.VIEW_PROJECTION_SHIFT, viewShift);
			}	
		}
		
		
		/* runs the unwarp job */
		public function update():void
		{	
			
			if ((_shader && _shaderHeight && !_shaderJob) || _sourceProjection.type == Projection.PLANAR) {
			/*	if (_needsSizeSync){
					syncDest();
				}
				if (_needsViewSync){
					syncView();
				}
				
				if (!_shaderJob) {
					/* update the source media */
				
					refreshSource();
					updateView();

					
					/* we need to put an exception in here for the planar case */
					if (_sourceProjection.type == Projection.PLANAR) 
					{
						var transformMatrix:Matrix = new Matrix();
						var scaleX:Number = _width/_sourceBitmap.width;
						var scaleY:Number = _height/_sourceBitmap.height;
						transformMatrix.scale(scaleX, scaleY);
						
						/*_projectedBitmap.draw(_sourceBitmap, transformMatrix, null, null, null, true);		*/
						_projectedBitmap.draw(_sourceBitmap, null, null, null, _clipRect, true);	
						
					} else {
						_shader.data.src.input = _sourceBitmap;
						_shaderJob = new ShaderJob(_shader, _projectedBitmap, _shaderWidth, _shaderHeight);
						//_shaderJob.addEventListener(ShaderEvent.COMPLETE, shaderJobComplete);
						_shaderJob.start(true);
						
						_projectedMedia.bitmapData = _projectedBitmap;
						_projectedMedia.smoothing = true;
						
						_shaderJob = null;
					}
					if (_needsRedraw){
						_needsRedraw = false;
					}
			}
		}
		
		public function busy():Boolean
		{
	
			if (_shaderJob){
				return true;
			} else {
				return false;
			}
			 
		}
		
		private function shaderJobComplete(e:ShaderEvent):void
		{
			_projectedMedia.bitmapData = _projectedBitmap;
			_projectedMedia.smoothing = true;
		/*	var transformMatrix:Matrix = new Matrix();
			var scaleX:Number = _width/_sourceBitmap.width;
			var scaleY:Number = _height/_sourceBitmap.height;
			transformMatrix.scale(scaleX, scaleY);
			var tempRect:Rectangle = new Rectangle(0, 0, _shaderWidth, _shaderHeight);
			_projectedBitmap.fillRect(tempRect, 0xFFFFFF);
			_projectedBitmap.draw(_sourceBitmap, null, null, null, null, true);*/	
			_shaderJob = null;
			if (_needsRedraw){
				update();	
			}
			
		}
		
		public function refreshSource():void
		{	
			/*_sourceBitmap.draw(_drawable, _transformMatrix, null, null, _clipRect, true);*/
			draw(_sourceBitmap, _drawable, _transformMatrix, null, null, _clipRect, false);
		}
		
		public function resize(width:Number, height:Number):void
		{
			_width = width;
			_height = height;
			_destProjection.aspectRatio = _width/_height;
			syncDest();
		}
		
		/*prepares the destination bitmap (_projectedMedia) */
		protected function syncDest():void
		{
			var mw:Number;
			var mh:Number;
			
			if (_width > _maxShaderWidth)
			{
				_shaderWidth = _maxShaderWidth;
				_shaderHeight = int(((_maxShaderWidth/_width) * _height));
			}
			else {
				_shaderWidth = _width;
				_shaderHeight = _height;
			}
			if (_destProjection.type == Projection.EQUIRECTANGULAR){
				_shaderHeight = (_sourceProjection.boundsDeg[3] / _sourceProjection.boundsDeg[2]) * _shaderWidth;
			}
			mw = _shaderWidth % 4;
			mh = _shaderHeight % 4;
			_shaderWidth += (mw) ? 4-mw : 0; 
			_shaderHeight += (mh) ? 4-mh : 0;		
			
			
	  		_projectedBitmap = new BitmapData(_shaderWidth, _shaderHeight, false, 0);
			
			if (_projectedMedia){
				_projectedMedia.bitmapData = _projectedBitmap;
				_projectedMedia.smoothing = true
				
			} else {
				_projectedMedia = new Bitmap(_projectedBitmap, "auto", true);
				_projectedMedia.smoothing = true
			}

			if (_shader && !_shaderJob) {	
				_shader.data.outputDimensions.value = [1.0/_shaderWidth, 1.0/_shaderHeight];
				_needsSizeSync = false;
			} else if (_shader){	
				_needsSizeSync = true;
				_needsRedraw = true;
			}
		}
		
		/* syncs changes to orientation, rotation, and viewBounds */
		public function syncView():void
		{
			
			if (_shaderJob && _shader){
				_needsViewSync = true;
				_needsRedraw = true;
				return;
			}
			
			if (_sourceProjection.type == Projection.PLANAR)
			{
				return;
			}
			
			if (_destProjection is ViewProjection) {
				var rectProjection:ViewProjection = _destProjection as ViewProjection;
				var viewBounds:Array = rectProjection.bounds;
				var orientation:Vector.<Number> = rectProjection.orientation.rawData;
				var rotationMatrix:Array = [
					orientation[0], orientation[1], orientation[2],
					orientation[4], orientation[5], orientation[6],
					orientation[8], orientation[9], orientation[10]
				];
				_shader.data.viewBounds.value = viewBounds;
				_shader.data.rotationMatrix.value = rotationMatrix;
				
			}
			
			_needsViewSync = false;
			
		}
			 
		protected function initShader():void
		{
			
			var fromType:String = _sourceProjection.type;
			var toType:String = _destProjection.type;

			switch (toType){
				case Projection.RECTILINEAR:
					initShaderHandlerToRectilinear(fromType, toType);	
					break;
				case Projection.EQUIRECTANGULAR:
					initShaderHandlerToEquirectangular(fromType, toType);
					break;
					
			 	default: throw("Cannot unwarp to " + toType);
				
			}
		}
		
		private function initShaderHandlerToRectilinear(fromType: String, toType: String): void{
			switch (fromType) {
				case Projection.EQUIRECTANGULAR:
					this.initShaderEquirectangularToRectilinear();
					break;
				case Projection.CYLINDRICAL:
					this.initShaderCylindricalToRectilinear();
					break;
				case Projection.EQUIANGULAR:
					this.initShaderEquiangularToRectilinear();
					break;
				case Projection.PLANAR:
					return;
					break;
				default:
					throw("Cannot unwarp from " + fromType + " to " + toType);
					
			}
			/* special data for rectilinear */
			syncView();
			
			
			_shader.precisionHint = ShaderPrecision.FULL;
			_shader.data.outputDimensions.value = [1.0/_shaderWidth, 1.0/_shaderHeight];
		}
		
		private function initShaderHandlerToEquirectangular(fromType: String, toType: String):void{
			switch (fromType) {
				case Projection.EQUIRECTANGULAR:
					this.initShaderEquirectangularToEquirectangular();
					break;
				case Projection.CYLINDRICAL:
					break;
				case Projection.EQUIANGULAR:
					break;
				case Projection.PLANAR:
					return;
					break;
				default:
					throw("Cannot unwarp from " + fromType + " to " + toType);
					
			}
			
			_shader.precisionHint = ShaderPrecision.FULL;
			_shader.data.outputDimensions.value = [1.0/_shaderWidth, 1.0/_shaderHeight];
		}
		
		private function initShaderEquirectangularToEquirectangular():void{
			_shader = new Shader( new EquirectangularToEquirectangularKernel() );
			var input:BitmapData = _sourceBitmap;
			_shader.data.src.input = input;
			_shader.data.inputDimensions.value = [input.width,input.height];
		}
		  	
		private function initShaderEquirectangularToRectilinear():void
		{
			_shader = new Shader( new EquirectangularToRectilinearKernel() );
			var input:BitmapData = _sourceBitmap;
			var bounds:Array = _sourceProjection.bounds;
			var newBounds:Array = [bounds[0], -1*(bounds[3]+bounds[1]), 1.0/bounds[2], 1.0/bounds[3]];
			_shader.data.src.input = input;
			_shader.data.inputDimensions.value = [input.width,input.height];
			/* we do this, because the equirectangular shader has a bug in it */
			_shader.data.equirectangularBoundsRad.value = newBounds;
		}
		
		private function initShaderCylindricalToRectilinear():void
		{
			_shader = new Shader( new CylindricalToRectilinearKernel() );
			var input:BitmapData = _sourceBitmap;
			var bounds:Array = _sourceProjection.bounds;
			_shader.data.src.input = input;
			_shader.data.inputDimensions.value = [input.width,input.height];
			/* we do this, because the equirectangular shader has a bug in it */
			
			
			// map angle to Y axis for bounds
			bounds[3] = Math.tan(bounds[1] + bounds[3]) - Math.tan(bounds[1]);
			bounds[1] = Math.tan(bounds[1]);
			var newBounds:Array = [bounds[0], -1*(bounds[3]+bounds[1]), 1.0/bounds[2], 1.0/bounds[3]];
			_shader.data.src.input = input;
			_shader.data.inputDimensions.value = [input.width,input.height];
			_shader.data.cylindricalBounds.value = newBounds;
		}
		
		private function initShaderEquiangularToRectilinear():void
		{
			_shader = new Shader( new EquiangularToRectilinearKernel() );
			var input:BitmapData = _sourceBitmap;
			_shader.data.src.input = input;
			_shader.data.inputDimensions.value = [input.width,input.height];
			
			/* This is not currently available, as the XML does not support 
				these properties */
			if ('center' in _sourceProjection) {
				var center:Array = _sourceProjection['center'];
				_shader.data.mirrorCenter.value = center;
			}
			if ('radius' in _sourceProjection) {
				var radius:Array = _sourceProjection['radius'];
				_shader.data.mirrorRadius.value = radius;
			}
			if ('range' in _sourceProjection) {
				var range:Array = _sourceProjection['range'];
				_shader.data.mirrorRange.value = range;
			}
			if ('flips' in _sourceProjection) {
				var flips:Number = _sourceProjection['flips'];
				var scaleX:Number = Math.pow(-1.0, flips);
				_shader.data.scaleX.value = scaleX;
			}
		}
		
		
		/* initializes the _sourceMedia, and links the bitmapData from the video/image
		to the _sourceMedia. */
		protected function initSource():void
		{
			
			/* It's important to get the true size here, not the drawn size.
			The subMediaProvider will take care of making sure the image/content
			is scaled appropriately. We have to fetch that scale... */
			var w:Number = 0;
			var h:Number = 0;
			var scaleX:Number = 1.0;
			var scaleY:Number = 1.0;
		
			if (_media is Video){
				var mediaVideo:Video = _media as Video;
				h = mediaVideo.videoHeight;
				w = mediaVideo.videoWidth;
				if (mediaVideo.videoHeight == 0 || mediaVideo.videoWidth == 0)
				{
					h = mediaVideo.height;
					w = mediaVideo.width;
				}
				scaleX = mediaVideo.scaleX;
				scaleY = mediaVideo.scaleY;
				_drawable = mediaVideo;
			} else if (_media is Loader) {
				var mediaLoader:Loader = _media as Loader;
				var mediaBitmap:Bitmap = mediaLoader as Bitmap;
				h = mediaBitmap.bitmapData.height;
				w = mediaBitmap.bitmapData.width;
				scaleX = 1.0;
				scaleY = 1.0;
				_drawable = mediaBitmap.bitmapData;
			}

			_transformMatrix = new Matrix();
			_transformMatrix.scale(scaleX, scaleY);
			
			/* we have to transform and scale approrpiately 
			   I commented this two lines out because it doesn't seem to do anything. -- Yan 
			*/	
//			_clipRect = _sourceProjection.getROIRect(w, h);
//			_transformMatrix.translate(-_clipRect.left, -_clipRect.top);
			
			/*if (w == 0 || h == 0){
				w = 320;
				h = 240;
				_width = 320;
				_height = 240;
			}*/
			_sourceBitmap = new BitmapData(w, h, false);
			/* just for now I'm going to leave the transform matrix out */
			/*_sourceBitmap.draw(_drawable, _transformMatrix, null, null, _clipRect, true);*/
			//_sourceBitmap.draw(_drawable, _transformMatrix, null, null, _clipRect, false);
			draw(_sourceBitmap, _drawable, _transformMatrix, null, null, _clipRect, false);
		}
		
		private function draw(bitmapData:BitmapData, source:IBitmapDrawable, matrix:Matrix, colorTransform:ColorTransform, blendMode:String, clipRect:Rectangle, smoothing:Boolean):void {
			// NetStream.play(null) + bitmapData.draw = Sandbox error 
			// Bug description: https://bugbase.adobe.com/index.cfm?event=bug&id=3617751
			// Workaround: http://gamespoweredby.com/blog/2014/11/netstream-playnull-bitmapdata-workaround/
			var vidContainer:Sprite = new Sprite();
			vidContainer.addChild(source);
			var bufferContainer:Sprite = new Sprite();
			// Works only with Flash 11.6 and newer
			// http://sleepydesign.blogspot.fr/2012/04/flash-swf-version-meaning.html
			var graphicsData:Vector.<IGraphicsData> = vidContainer.graphics.readGraphicsData()
			bufferContainer.graphics.drawGraphicsData(graphicsData);
			bitmapData.draw(bufferContainer, matrix, colorTransform, blendMode, clipRect, smoothing);
			
		}
		
		public function get media():Bitmap
		{
			
			return _projectedMedia;
			
		}
		
		public function adjustPan(degrees:Number):void
		{
			_destProjection.pan = _destProjection.pan + degrees;
			
		}
		
		public function get pan():Number
		{
			return _destProjection.pan;	
		}
		
		public function set pan(x:Number):void
		{	
			_destProjection.pan = x;
		}
		
		public function set tilt(x:Number):void
		{
			_destProjection.tilt = x;	
		}
		
		public function get tilt():Number
		{
			return _destProjection.tilt;	
		
		}
	
		public function get width():Number
		{
			return _width;
		}
		
		public function get scaleX():Number
		{
			return _width/_shaderWidth;	
		}
		
		public function get scaleY():Number
		{
			return _height/_shaderHeight;
		}
		
		public function get height():Number
		{
			return _height;
		}
		
		public function get horizontalFOV():Number
		{
			return _destProjection.horizontalFOV;	
		}
		
		public function set horizontalFOV(x:Number):void
		{
			_destProjection.horizontalFOV = x;
		}
		
		public function set verticalFOV(x:Number):void
		{
			_destProjection.verticalFOV = x;
		}
		
		public function get verticalFOV():Number
		{
			return _destProjection.verticalFOV;	
		}
		
		public function set panVelocity(x:Number):void
		{
			_panVelocity = x;	
		}
		
		public function get panVelocity():Number
		{
			return _panVelocity;
		}
		
		public function set tiltVelocity(x:Number):void
		{
			_tiltVelocity = x;
			
		}
		
		public function get tiltVelocity():Number
		{
			return _tiltVelocity;	
		}
		
		public function set zoomVelocity(x:Number):void
		{
			_zoomVelocity = x;	
		}
		
		public function get zoomVelocity():Number
		{
			return _zoomVelocity;	
		}
	}
}