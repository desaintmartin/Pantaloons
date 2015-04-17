/**
 * Manages playback of http streaming flv.
 **/
package com.longtailvideo.jwplayer.media {
	
	import org.mangui.HLS.parsing.Level;
	import org.mangui.HLS.*;
	import org.mangui.HLS.utils.Log;
	import org.mangui.HLS.utils.ScaleVideo;

	import com.longtailvideo.jwplayer.events.MediaEvent;
	import com.longtailvideo.jwplayer.model.PlayerConfig;
	import com.longtailvideo.jwplayer.model.PlaylistItem;
	import com.longtailvideo.jwplayer.player.PlayerState;
	import com.longtailvideo.jwplayer.utils.NetClient;
	
	import flash.events.*;
	import flash.media.*;
	import flash.net.*;
	import flash.utils.*;
	import flash.display.DisplayObject;


	public class HLSMediaProvider extends MediaProvider {
		
		/** Reference to the framework. **/
		protected var _hls : HLS;
		/** Current quality level. **/
		protected var _level : Number;
		/** Reference to the quality levels. **/
		protected var _levels : Vector.<Level>;
		/** current position **/
		protected var _media_position : Number;		
		/** Video Original size **/
		private var _videoWidth : Number = 0;
		private var _videoHeight : Number = 0;
		private var _seekInLiveDurationThreshold : Number = 60;
		
		
		
		/** NetConnection object for setup of the video stream. **/
		protected var _connection:NetConnection;
		/** NetStream instance that handles the stream IO. **/
		protected var _stream:NetStream;
		/** Video object to be instantiated. **/
		protected var _video:Video;
		/** Sound control object. **/
		protected var _transformer:SoundTransform;
		/** ID for the _position interval. **/
		protected var _positionInterval:Number;
		/** Save whether metadata has already been sent. **/
		protected var _meta:Boolean;
		/** Object with keyframe times and positions. **/
		protected var _keyframes:Object;
		/** Offset in bytes of the last seek. **/
		protected var _byteoffset:Number;
		/** Offset in seconds of the last seek. **/
		protected var _timeoffset:Number = 0;
		/** Boolean for mp4 / flv streaming. **/
		protected var _mp4:Boolean;
		/** Load offset for bandwidth checking. **/
		protected var _loadtimer:Number;
		/** Variable that takes reloading into account. **/
		protected var _iterator:Number;
		/** Start parameter. **/
		private var _startparam:String = 'start';
		/** Whether the buffer has filled **/
		private var _bufferFull:Boolean;
		/** Whether the enitre video has been buffered **/
		private var _bufferingComplete:Boolean;
		
		/** Constructor; sets up the connection and display. **/
		public function HLSMediaProvider() {
			super('hls');
		}

		public override function getRawMedia():DisplayObject
		{
			return _video;
			
		}

		public override function initializeMediaProvider(cfg:PlayerConfig):void {
			super.initializeMediaProvider(cfg);
			
			_hls = new HLS();
			_hls.stream.soundTransform = new SoundTransform(cfg.volume / 100);
			
			/*_hls.addEventListener(HLSEvent.PLAYBACK_COMPLETE, _completeHandler);
			_hls.addEventListener(HLSEvent.ERROR, _errorHandler);
			_hls.addEventListener(HLSEvent.FRAGMENT_LOADED, _fragmentHandler);
			_hls.addEventListener(HLSEvent.MANIFEST_LOADED, _manifestHandler);
			_hls.addEventListener(HLSEvent.PLAYBACK_STATE, _stateHandler);
			_hls.addEventListener(HLSEvent.AUDIO_ONLY, _audioHandler);	*/		
			
			_connection = new NetConnection();
			_connection.connect(null);
			//_stream = new NetStream(_connection);
			_hls.minBufferLength=cfg.hls_minbufferlength;
			_hls.maxBufferLength=cfg.hls_maxbufferlength;
			_hls.lowBufferLength=cfg.hls_lowbufferlength;
			_hls.startFromLowestLevel=false;
			_hls.flushLiveURLCache=true;
			
			Log.LOG_DEBUG_ENABLED = cfg.hls_debug as Boolean;
			Log.LOG_DEBUG2_ENABLED = cfg.hls_debug2 as Boolean;
			
			_stream=_hls.stream;
			
			
			_stream.checkPolicyFile = true;
			_stream.addEventListener(NetStatusEvent.NET_STATUS, statusHandler);
			_stream.addEventListener(IOErrorEvent.IO_ERROR, errorHandler);
			_stream.addEventListener(AsyncErrorEvent.ASYNC_ERROR, errorHandler);
			_stream.bufferTime = config.bufferlength;
			_stream.client = new NetClient(this);
			_video = new Video(320, 240);
			_video.smoothing = config.smoothing;
			
			_video.attachNetStream(_stream);
			
			
			_transformer = new SoundTransform();
			_byteoffset = _timeoffset = 0;
		}

		/** Forward completes from the framework. **/
		private function _completeHandler(event : HLSEvent) : void {
			complete();
		};
		
		/** Forward playback errors from the framework. **/
		private function _errorHandler(event : HLSEvent) : void {
			error('hls, Error: ' + event.error.msg);
			super.error(event.error.msg);
		};
		
		/** Forward QOS metrics on fragment load. **/
		protected function _fragmentHandler(event : HLSEvent) : void {
			_level = event.metrics.level;
			sendMediaEvent(MediaEvent.JWPLAYER_MEDIA_META, {metadata:{bandwidth:Math.round(event.metrics.bandwidth / 1024), droppedFrames:_hls.stream.info.droppedFrames, currentLevel:(_level + 1) + ' of ' + _levels.length + ' (' + Math.round(_levels[_level].bitrate / 1024) + 'kbps, ' + _levels[_level].width + 'px)', width:_videoWidth}});
		};
		
		/** Update video A/R on manifest load. **/
		private function _manifestHandler(event : HLSEvent) : void {
			_levels = event.levels;
			// only report position/duration/buffer for VOD playlist and live playlist with duration > _seekInLiveDurationThreshold
			if (_hls.type == HLSTypes.VOD || _levels[0].duration > _seekInLiveDurationThreshold) {
				item.duration = _levels[0].duration;
			} else {
				item.duration = -1;
			}
			sendMediaEvent(MediaEvent.JWPLAYER_MEDIA_TIME, {position:0, duration:item.duration});
			_hls.addEventListener(HLSEvent.MEDIA_TIME, _mediaTimeHandler);
			/* start playback on manifest load */
			if (item.start != 0) {
				_hls.stream.seek(item.start);
			} else {
				// look at super.play()
				_hls.stream.play();
			}
		};
		
		/** Update playback position. **/
		private function _mediaTimeHandler(event : HLSEvent) : void {
			// only report position/duration/buffer for VOD playlist and live playlist with duration > _seekInLiveDurationThreshold
			if (_hls.type == HLSTypes.VOD || event.mediatime.duration > _seekInLiveDurationThreshold) {
				item.duration = event.mediatime.duration;
				_media_position = Math.max(0, event.mediatime.position);
				var _bufferPercent : Number = 100 * (_media_position + event.mediatime.buffer) / event.mediatime.duration;
				sendMediaEvent(MediaEvent.JWPLAYER_MEDIA_TIME, {bufferPercent:_bufferPercent, offset:0, position:_media_position, duration:event.mediatime.duration});
				Log.info("video duration  :" + event.mediatime.duration);
			}
			var videoWidth : Number;
			var videoHeight : Number;
			videoWidth = _video.videoWidth;
			videoHeight = _video.videoHeight;
			media = _video;
			
			if (videoWidth && videoHeight) {
				if (_videoWidth != videoWidth || _videoHeight != videoHeight) {
					_videoHeight = videoHeight;
					_videoWidth = videoWidth;
					Log.info("video size changed to " + _videoWidth + "/" + _videoHeight);
					// force resize to adjust video A/R
					resize(_width, _height);
					//resize(_stageVideo.videoWidth, _stageVideo.videoHeight);
				}
			}
		};
		
		/** Forward state changes from the framework. **/
		private function _stateHandler(event : HLSEvent) : void {
			switch(event.state) {
				case HLSPlayStates.IDLE:
					setState(PlayerState.IDLE);
					break;
				case HLSPlayStates.PLAYING_BUFFERING:
				case HLSPlayStates.PAUSED_BUFFERING:
					setState(PlayerState.BUFFERING);
					sendBufferEvent(0, 0);
					sendMediaEvent(MediaEvent.JWPLAYER_MEDIA_LOADED);
					
					_bufferingComplete = true;					
					break;
				case HLSPlayStates.PLAYING:
					_video.visible = true;
					setState(PlayerState.PLAYING);
					break;
				case HLSPlayStates.PAUSED:
					setState(PlayerState.PAUSED);
					break;
			}
		};
		
		private function _audioHandler(e : Event) : void {
			media = null;
			// sendMediaEvent(MediaEvent.JWPLAYER_MEDIA_LOADED);
			// dispatchEvent(new MediaEvent(MediaEvent.JWPLAYER_MEDIA_LOADED));
		}

		
		
		
		
		
		/** Convert seekpoints to keyframes. **/
		protected function convertSeekpoints(dat:Object):Object {
			var kfr:Object = new Object();
			kfr.times = new Array();
			kfr.filepositions = new Array();
			for (var j:String in dat) {
				kfr.times[j] = Number(dat[j]['time']);
				kfr.filepositions[j] = Number(dat[j]['offset']);
			}
			return kfr;
		}


		/** Catch security errors. **/
		protected function errorHandler(evt:ErrorEvent):void {
			error(evt.text);
		}


		/** Return a keyframe byteoffset or timeoffset. **/
		protected function getOffset(pos:Number, tme:Boolean=false):Number {
			if (!_keyframes) {
				return 0;
			}
			for (var i:Number = 0; i < _keyframes.times.length - 1; i++) {
				if (_keyframes.times[i] <= pos && _keyframes.times[i + 1] >= pos) {
					break;
				}
			}
			if (tme == true) {
				return _keyframes.times[i];
			} else {
				return _keyframes.filepositions[i];
			}
		}

		public override function getTime():Number
		{
			if (this._stream)
			{
				return _stream.time;
			} else {
				
				return -1;
			}
			
		}

		/** Create the video request URL. **/
		protected function getURL():String {
			var url:String = item.file;
			var off:Number = _byteoffset;
			/*if (getConfigProperty('startparam') as String) {
				_startparam = getConfigProperty('startparam');
			}
			if (item.streamer) {
				if (item['streamer'].indexOf('/') > 0) {
					url = item.streamer;
					url = getURLConcat(url, 'file', item.file);
				} else {
					_startparam = item.streamer;
				}
			}
			if (_mp4) {
				off = _timeoffset;
			} else if (_startparam == 'starttime') {
				_startparam = 'start';
			}
			if (off > 0) {
				url = getURLConcat(url, _startparam, off);
			}*/
			
			url = item.file;
			return url;
		}


		/** Concatenate a parameter to the url. **/
		private function getURLConcat(url:String, prm:String, val:*):String {
			if (url.indexOf('?') > -1) {
				return url + '&' + prm + '=' + val;
			} else {
				return url + '?' + prm + '=' + val;
			}
		}


		/** Load content. **/
		override public function load(itm:PlaylistItem):void {
			_item = itm;
			_position = _timeoffset;
			_bufferFull = false;
			_bufferingComplete = false;
			if (_stream.bytesLoaded + _byteoffset < _stream.bytesTotal) {
				_stream.close();
			}
			media = _video;
			//_stream.play(getURL());
			Log.info("opening HLS URL : " + itm.file);
			_hls.load(item.file);

			if (!_positionInterval) {
				_positionInterval = setInterval(positionInterval, 100);
			}
			if (!_loadtimer) {
				_loadtimer = setTimeout(loadTimeout, 3000);
			}
			setState(PlayerState.BUFFERING);
			sendBufferEvent(0, 0);
			sendMediaEvent(MediaEvent.JWPLAYER_MEDIA_LOADED);
			config.mute == true ? setVolume(0) : setVolume(config.volume);
		}


		/** timeout for checking the bitrate. **/
		protected function loadTimeout():void {
			var obj:Object = new Object();
			obj.bandwidth = Math.round(_stream.bytesLoaded / 1024 / 3 * 8);
			if (item.duration) {
				obj.bitrate = Math.round(_stream.bytesTotal / 1024 * 8 / item.duration);
			}
			sendMediaEvent(MediaEvent.JWPLAYER_MEDIA_META, {metadata: obj});
		}


		/** Get metadata information from netstream class. **/
		public function onData(dat:Object):void {
			if (dat.width) {
				_video.width = dat.width;
				_video.height = dat.height;
				resize(_width, _height);
			}
			if (dat.duration && item.duration <= 0) {
				item.duration = dat.duration;
			}
			if (dat['type'] == 'metadata' && !_meta) {
				_meta = true;
				if (dat.seekpoints) {
					_mp4 = true;
					_keyframes = convertSeekpoints(dat.seekpoints);
				} else {
					_mp4 = false;
					_keyframes = dat.keyframes;
				}
				if (item.start > 0) {
					seek(item.start);
				}
			}
			sendMediaEvent(MediaEvent.JWPLAYER_MEDIA_META, {metadata: dat});
		}


		/** Pause playback. **/
		override public function pause():void {
			_stream.pause();
			super.pause();
		}


		/** Resume playing. **/
		override public function play():void {
			_stream.resume();
			if (!_positionInterval) {
				_positionInterval = setInterval(positionInterval, 100);
			}
			super.play();
		}


		/** Interval for the position progress **/
		protected function positionInterval():void {
			_position = Math.round(_stream.time * 10) / 10;
			var percentoffset:Number;
			if (_mp4) {
				_position += _timeoffset;
			}
			
			var bufferPercent:Number;
			var bufferFill:Number;
			if (item.duration > 0) {
				percentoffset =  Math.round(_timeoffset /  item.duration * 100);
				bufferPercent = (_stream.bytesLoaded / _stream.bytesTotal) * (1 - _timeoffset / item.duration) * 100;
				var bufferTime:Number = _stream.bufferTime < (item.duration - position) ? _stream.bufferTime : Math.round(item.duration - position);
				bufferFill = _stream.bufferTime == 0 ? 0 : Math.ceil(_stream.bufferLength / bufferTime * 100);
			} else {
				percentoffset = 0;
				bufferPercent = 0;
				bufferFill = _stream.bufferLength/_stream.bufferTime * 100;
			}

			if (bufferFill < 25 && state == PlayerState.PLAYING) {
				_bufferFull = false;
				_stream.pause();
				setState(PlayerState.BUFFERING);
			} else if (bufferFill > 95 && state == PlayerState.BUFFERING && _bufferFull == false) {
				_bufferFull = true;
				sendMediaEvent(MediaEvent.JWPLAYER_MEDIA_BUFFER_FULL);
			}

			if (state == PlayerState.BUFFERING || state == PlayerState.PAUSED) {
				if (!_bufferingComplete) {
					if ((bufferPercent + percentoffset) == 100 && _bufferingComplete == false) {
						_bufferingComplete = true;
					}
					sendBufferEvent(bufferPercent, _timeoffset);
					
				}
			} else if (_position < item.duration) {
				if (state == PlayerState.PLAYING && _position >= 0) {
					sendMediaEvent(MediaEvent.JWPLAYER_MEDIA_TIME, {position: _position, duration: item.duration, bufferPercent: bufferPercent, offset: _timeoffset});
				}
			} else if (item.duration > 0) {
				// Playback completed
				complete();
			}
		}


		/** Seek to a specific second. **/
		override public function seek(pos:Number):void {
			var off:Number = getOffset(pos);
			super.seek(pos);
			clearInterval(_positionInterval);
			_positionInterval = undefined;
			if (off < _byteoffset || off >= _byteoffset + _stream.bytesLoaded) {
				_timeoffset = _position = getOffset(pos, true);
				_byteoffset = off;
				load(item);
			} else {
				if (state == PlayerState.PAUSED) {
					_stream.resume();
				}
				_position = pos;
				if (_mp4) {
					_stream.seek(getOffset(_position - _timeoffset, true));
				} else {
					_stream.seek(getOffset(_position, true));
				}
				play();
			}
		}


		/** Receive NetStream status updates. **/
		protected function statusHandler(evt:NetStatusEvent):void {
			switch (evt.info.code) {
				case "NetStream.Play.Stop":
					if (state != PlayerState.BUFFERING) {
						complete();
					}
					break;
				case "NetStream.Play.StreamNotFound":
					stop();
					error('http, Video not found: ' + item.file);
					break;
				case 'NetStream.Buffer.Full':
					if (!_bufferFull) {
						_bufferFull = true;
						sendMediaEvent(MediaEvent.JWPLAYER_MEDIA_BUFFER_FULL);
					}
					break;
			}
			sendMediaEvent(MediaEvent.JWPLAYER_MEDIA_META, {metadata: {status: evt.info.code}});
		}


		/** Destroy the HTTP stream. **/
		override public function stop():void {
			if (_stream.bytesLoaded + _byteoffset < _stream.bytesTotal) {
				_stream.close();
			} else {
				_stream.pause();
			}
			clearInterval(_positionInterval);
			_positionInterval = undefined;
			_position = _byteoffset = _timeoffset = 0;
			_keyframes = undefined;
			_meta = false;
			super.stop();
		}


		/** Set the volume level. **/
		override public function setVolume(vol:Number):void {
			_transformer.volume = vol / 100;
			_stream.soundTransform = _transformer;
			super.setVolume(vol);
		}
	}
}
