package com.danieljansen.chefpocket;

import android.content.Context;
import android.content.res.AssetFileDescriptor;
import android.media.AudioAttributes;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import android.media.MediaPlayer;
import android.util.Base64;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.util.List;
import java.util.function.Consumer;

/** Selected Fish Chef voice, generated from fixed public confirmations. No API key on phone. */
final class PhoneVoice {
    private final Context context;
    private final Consumer<String> error;
    private final Consumer<Boolean> playback;
    private final AudioManager audio;
    private MediaPlayer player;
    private AudioFocusRequest focus;
    private File playbackFile;
    private boolean playbackActive;
    PhoneVoice(Context context, Consumer<String> error) {
        this(context,error,muted->{});
    }
    PhoneVoice(Context context,Consumer<String> error,Consumer<Boolean> playback) {
        this.context=context.getApplicationContext();this.error=error;
        this.playback=playback;
        audio=(AudioManager)this.context.getSystemService(Context.AUDIO_SERVICE);
    }
    void speak(String text) {
        close(); String clip=clipFor(text);
        if(clip==null){error.accept("Chef voice has no recording for this reply.");return;}
        try {
            AudioAttributes attributes=new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build();
            focus=new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK).setAudioAttributes(attributes).setOnAudioFocusChangeListener(change->{if(change==AudioManager.AUDIOFOCUS_LOSS||change==AudioManager.AUDIOFOCUS_LOSS_TRANSIENT)close();}).build();
            if(audio.requestAudioFocus(focus)!=AudioManager.AUDIOFOCUS_REQUEST_GRANTED){close();error.accept("Chef audio is busy. Try Test Chef voice again.");return;}
            MediaPlayer next=new MediaPlayer();player=next;next.setAudioAttributes(attributes);
            try(AssetFileDescriptor file=context.getAssets().openFd("chef-voice/"+clip+".mp3")){next.setDataSource(file.getFileDescriptor(),file.getStartOffset(),file.getLength());}
            next.setOnPreparedListener(p->{if(player==p){setPlaybackActive(true);p.start();}});
            next.setOnCompletionListener(p->{if(player==p)close();});
            next.setOnErrorListener((p,what,extra)->{if(player==p){close();error.accept("Chef voice could not play. Check Media volume and audio output.");}return true;});
            setPlaybackActive(true);
            next.prepareAsync();
        } catch(Exception ignored){close();error.accept("Chef voice could not play. Check Media volume and audio output.");}
    }
    void playChunks(List<PocketStore.VoiceChunk> chunks){
        close();try{
            if(chunks==null||chunks.isEmpty()||chunks.size()>32)throw new IllegalArgumentException();int count=chunks.get(0).count;if(count!=chunks.size())throw new IllegalArgumentException();
            ByteArrayOutputStream bytes=new ByteArrayOutputStream();for(int i=0;i<count;i++){PocketStore.VoiceChunk chunk=chunks.get(i);if(chunk.index!=i||chunk.count!=count)throw new IllegalArgumentException();byte[] decoded=Base64.decode(chunk.data,Base64.DEFAULT);if(decoded.length>6000||bytes.size()+decoded.length>192_000)throw new IllegalArgumentException();bytes.write(decoded);}
            if(bytes.size()==0)throw new IllegalArgumentException();File file=File.createTempFile("chef-reply-",".mp3",context.getCacheDir());playbackFile=file;try(FileOutputStream out=new FileOutputStream(file)){bytes.writeTo(out);}
            AudioAttributes attributes=new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build();
            focus=new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK).setAudioAttributes(attributes).setOnAudioFocusChangeListener(change->{if(change==AudioManager.AUDIOFOCUS_LOSS||change==AudioManager.AUDIOFOCUS_LOSS_TRANSIENT)close();}).build();
            if(audio.requestAudioFocus(focus)!=AudioManager.AUDIOFOCUS_REQUEST_GRANTED)throw new IllegalStateException();
            MediaPlayer next=new MediaPlayer();player=next;next.setAudioAttributes(attributes);next.setDataSource(file.getAbsolutePath());next.setOnPreparedListener(p->{if(player==p){p.start();}});next.setOnCompletionListener(p->{if(player==p)close();});next.setOnErrorListener((p,what,extra)->{if(player==p){close();error.accept("Chef reply audio could not play. The text reply is saved.");}return true;});setPlaybackActive(true);next.prepareAsync();
        }catch(Exception ignored){close();error.accept("Chef reply audio is incomplete. The text reply is saved.");}
    }
    static String clipFor(String text) {
        switch(text){
            case "I'm listening.":return "listening";
            case "Saved to your to-do list.":return "todo";
            case "Saved to your thoughts.":return "thought";
            case "To-do removed.":return "todo_removed";
            case "I found more than one matching to-do. Please be more specific.":return "todo_ambiguous";
            case "I couldn't find that to-do.":return "todo_not_found";
            case "Calendar event added on this phone.":return "calendar_added";
            case "Calendar request saved. Chef Pocket could not add it yet.":return "calendar_failed";
            case "Calendar request saved. Choose a calendar in Chef Pocket.":return "calendar_choose";
            case "I couldn't save that. Try again in Chef Pocket.":return "save_failed";
            case "That capture is too long. Try a shorter one.":return "too_long";
            case "Okay, capture canceled.":return "canceled";
            case "That voice capture timed out. Say hey chef again.":return "capture_timeout";
            case "I didn't hear a capture. Say hey chef again.":return "no_capture";
            case "Chef Pocket voice capture stopped.":return "stopped";
            case "Chef Pocket voice capture timed out.":return "timed_out";
            case "Hello. I'm Chef. My voice is ready.":return "speaker_test";
            default:return null;
        }
    }
    private void setPlaybackActive(boolean active){if(playbackActive==active)return;playbackActive=active;try{playback.accept(active);}catch(Exception ignored){}}
    void close(){setPlaybackActive(false);MediaPlayer old=player;player=null;if(old!=null)old.release();AudioFocusRequest oldFocus=focus;focus=null;if(oldFocus!=null)audio.abandonAudioFocusRequest(oldFocus);File oldFile=playbackFile;playbackFile=null;if(oldFile!=null)oldFile.delete();}
}
