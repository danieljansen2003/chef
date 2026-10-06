package com.danieljansen.chefpocket;

import android.media.AudioFormat;
import android.media.AudioRecord;
import android.media.MediaRecorder;
import android.os.Handler;
import android.os.Looper;
import org.json.JSONObject;
import org.vosk.Model;
import org.vosk.Recognizer;
import org.vosk.android.RecognitionListener;
import java.io.IOException;

/** One AudioRecord stream feeding a constrained wake decoder and an unrestricted decoder. */
final class DualRecognizerAudioService {
    static final float SAMPLE_RATE=16_000.0f;
    static final String WAKE_GRAMMAR="[\"hey chef\", \"[unk]\"]";
    interface WakeListener { void onWakePhrase(); }
    private static final int FRAME_SAMPLES=3_200;
    private final AudioRecord recorder;
    private final Recognizer wakeRecognizer;
    private final Recognizer commandRecognizer;
    private final Model model;
    private final Handler main=new Handler(Looper.getMainLooper());
    private volatile boolean active;
    private Thread thread;
    private RecognitionListener listener;
    private WakeListener wakeListener;
    private Runnable audioStarted;
    private boolean wakeReported;
    private boolean resourcesClosed;

    DualRecognizerAudioService(Model model,Recognizer wakeRecognizer,Recognizer commandRecognizer)throws IOException{
        this.model=model;this.wakeRecognizer=wakeRecognizer;this.commandRecognizer=commandRecognizer;
        int min=AudioRecord.getMinBufferSize((int)SAMPLE_RATE,AudioFormat.CHANNEL_IN_MONO,AudioFormat.ENCODING_PCM_16BIT);
        if(min<=0)throw new IOException("Android could not configure microphone audio.");
        int bytes=Math.max(min,FRAME_SAMPLES*2);
        try { recorder=new AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION,(int)SAMPLE_RATE,AudioFormat.CHANNEL_IN_MONO,AudioFormat.ENCODING_PCM_16BIT,bytes); } catch(SecurityException denied) { throw new IOException("Microphone permission is unavailable. Enable it in Android settings.",denied); }
        if(recorder.getState()!=AudioRecord.STATE_INITIALIZED){recorder.release();throw new IOException("Android could not initialize the microphone recorder.");}
    }

    synchronized boolean startListening(RecognitionListener listener,WakeListener wakeListener,Runnable audioStarted){
        if(thread!=null)return false;
        this.listener=listener;this.wakeListener=wakeListener;this.audioStarted=audioStarted;active=true;
        thread=new Thread(this::recordLoop,"chef-dual-vosk-audio");thread.start();return true;
    }

    private void recordLoop(){short[] samples=new short[FRAME_SAMPLES];try{
        if(!active)return;
        recorder.startRecording();
        if(!active)return;
        if(recorder.getRecordingState()!=AudioRecord.RECORDSTATE_RECORDING)throw new IOException("Android did not start microphone recording.");
        Runnable ready=audioStarted;if(ready!=null)main.post(ready);
        while(active&&!Thread.currentThread().isInterrupted()){
            int count=recorder.read(samples,0,samples.length,AudioRecord.READ_BLOCKING);
            if(!active)break;
            if(count<0)throw new IOException("Android microphone read failed ("+count+").");
            if(count==0)continue;
            feedWake(samples,count);
            boolean endpoint=commandRecognizer.acceptWaveForm(samples,count);
            if(endpoint){String result=commandRecognizer.getResult();postResult(result);}else{String partial=commandRecognizer.getPartialResult();postPartial(partial);}
        }
    }catch(Exception error){if(active){active=false;main.post(()->{if(listener!=null)listener.onError(error);});}}
    finally{
        active=false;
        try{if(recorder.getRecordingState()==AudioRecord.RECORDSTATE_RECORDING)recorder.stop();}catch(Exception ignored){}
        java.util.Arrays.fill(samples,(short)0);
        closeResources();
    }}

    private void feedWake(short[] samples,int count){
        if(wakeRecognizer.acceptWaveForm(samples,count)){
            try{if(!wakeReported&&WakePhraseMachine.isWakeGrammarText(new JSONObject(wakeRecognizer.getResult()).optString("text",""))){wakeReported=true;reportWake();}}
            catch(Exception ignored){}
            wakeReported=false;wakeRecognizer.reset();
        }else if(!wakeReported){
            try{String partial=new JSONObject(wakeRecognizer.getPartialResult()).optString("partial","");if(WakePhraseMachine.isWakeGrammarText(partial)){wakeReported=true;reportWake();}}
            catch(Exception ignored){}
        }
    }
    private void reportWake(){WakeListener callback=wakeListener;if(callback!=null)main.post(callback::onWakePhrase);}
    private void postResult(String json){RecognitionListener callback=listener;if(callback!=null)main.post(()->callback.onResult(json));}
    private void postPartial(String json){RecognitionListener callback=listener;if(callback!=null)main.post(()->callback.onPartialResult(json));}

    void stop(){active=false;try{if(recorder.getRecordingState()==AudioRecord.RECORDSTATE_RECORDING)recorder.stop();}catch(Exception ignored){}Thread current=thread;if(current==null){closeResources();return;}if(current!=Thread.currentThread()){current.interrupt();try{current.join(2500);}catch(InterruptedException e){Thread.currentThread().interrupt();}if(!current.isAlive())closeResources();}}

    private synchronized void closeResources(){if(resourcesClosed)return;resourcesClosed=true;try{wakeRecognizer.close();}catch(Exception ignored){}try{commandRecognizer.close();}catch(Exception ignored){}try{recorder.release();}catch(Exception ignored){}try{model.close();}catch(Exception ignored){}}
}
