package com.danieljansen.chefpocket;

import android.content.Context;
import android.content.res.AssetFileDescriptor;
import android.media.AudioAttributes;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import android.media.MediaPlayer;
import java.util.function.Consumer;

/** Selected Fish Chef voice, generated from fixed public confirmations. No API key on phone. */
final class PhoneVoice {
    private final Context context;
    private final Consumer<String> error;
    private final AudioManager audio;
    private MediaPlayer player;
    private AudioFocusRequest focus;
    PhoneVoice(Context context, Consumer<String> error) {
        this.context=context.getApplicationContext();this.error=error;
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
            next.setOnPreparedListener(p->{if(player==p)p.start();});
            next.setOnCompletionListener(p->{if(player==p)close();});
            next.setOnErrorListener((p,what,extra)->{if(player==p){close();error.accept("Chef voice could not play. Check Media volume and audio output.");}return true;});
            next.prepareAsync();
        } catch(Exception ignored){close();error.accept("Chef voice could not play. Check Media volume and audio output.");}
    }
    static String clipFor(String text) {
        switch(text){
            case "I'm listening.":return "listening";
            case "Saved to your to-do list.":return "todo";
            case "Saved to your thoughts.":return "thought";
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
    void close(){MediaPlayer old=player;player=null;if(old!=null)old.release();AudioFocusRequest oldFocus=focus;focus=null;if(oldFocus!=null)audio.abandonAudioFocusRequest(oldFocus);}
}
