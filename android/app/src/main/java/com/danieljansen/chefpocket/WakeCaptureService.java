package com.danieljansen.chefpocket;

import android.Manifest;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.PowerManager;
import org.json.JSONObject;
import org.vosk.Model;
import org.vosk.Recognizer;
import org.vosk.android.RecognitionListener;
import org.vosk.android.SpeechService;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.util.Locale;

/** User-started foreground listener. Recognition and audio stay on device. */
public final class WakeCaptureService extends Service implements RecognitionListener {
    private static volatile boolean running;
    private static volatile boolean starting;
    static boolean isRunning(){return running||starting;}
    static final String ACTION_START="com.danieljansen.chefpocket.START_WAKE";
    static final String ACTION_STOP="com.danieljansen.chefpocket.STOP_WAKE";
    static final String ACTION_TALK_NOW="com.danieljansen.chefpocket.TALK_NOW";
    static final String ACTION_STATE="com.danieljansen.chefpocket.WAKE_STATE";
    static final String EXTRA_STATE="state";
    private static final String CHANNEL="chef-pocket-listening";
    private static final int NOTIFICATION_ID=7301;
    private static final long MAX_LISTEN_MS=12L*60L*60L*1000L;
    private final Handler handler=new Handler(Looper.getMainLooper());
    private final WakePhraseMachine machine=new WakePhraseMachine();
    private String pendingCommand;
    private final Runnable deadlineCheck=new Runnable(){@Override public void run(){WakePhraseMachine.Result r=machine.expire(android.os.SystemClock.elapsedRealtime());if(r.kind==WakePhraseMachine.ResultKind.TIMEOUT){wakeAcknowledged=false;wakeFeedbackSpoken=false;pendingCommand=null;setNotice("Listening for “hey chef”");sendState("Listening for hey chef");}if(machine.mode()==WakePhraseMachine.Mode.COMMAND)handler.postDelayed(this,500);}};
    private final Runnable settleCapture=()->{String text=pendingCommand;pendingCommand=null;if(text!=null)saveCapture(text);};
    private final Runnable captureTimeout=()->{if(pendingCommand!=null){pendingCommand=null;machine.reset();handler.removeCallbacks(settleCapture);handler.removeCallbacks(deadlineCheck);setNotice("Command timed out · listening for “hey chef”");sendState("Command timed out · please say hey chef again");speakFeedback("That voice capture timed out. Say hey chef again.");}};
    private final Runnable relayRetry=new Runnable(){@Override public void run(){if(stopping||!running)return;try{if(PocketStore.readToken(WakeCaptureService.this)!=null)RelaySync.request(WakeCaptureService.this);}catch(Exception ignored){}handler.postDelayed(this,30_000);}};
    private SpeechService speechService;
    private Model model;
    private Recognizer offlineRecognizer;
    private String lastUtterance="";
    private long lastUtteranceAt;
    private long lastPartialStatusAt;
    private long pendingStartedAt;
    private boolean wakeAcknowledged;
    private boolean wakeFeedbackSpoken;
    private int startGeneration;
    private boolean manualArmPending;
    private volatile boolean stopping;
    private PowerManager.WakeLock wakeLock;
    private PhoneVoice phoneVoice;
    private final Runnable autoStop=()->{sendState("Handsfree stopped after 12 hours. Enable it again in Chef Pocket if needed.");stopSelf();};

    @Override public void onCreate(){super.onCreate();createChannel();}
    @Override public int onStartCommand(Intent intent,int flags,int startId){
        if(intent!=null&&ACTION_STOP.equals(intent.getAction())){synchronized(this){stopping=true;startGeneration++;starting=false;running=false;}handler.removeCallbacksAndMessages(null);pendingCommand=null;stopSelf();return START_NOT_STICKY;}
        if(intent!=null&&ACTION_TALK_NOW.equals(intent.getAction())){if(running)handler.post(this::armManualCapture);else if(starting)manualArmPending=true;else sendState("Voice capture is not running · enable handsfree first");return START_NOT_STICKY;}
        if(running||starting)return START_NOT_STICKY;
        if(checkSelfPermission(Manifest.permission.RECORD_AUDIO)!=PackageManager.PERMISSION_GRANTED){stopSelf();return START_NOT_STICKY;}
        try{
            Notification notification=notification("Starting offline voice capture · tap Stop to end");
            if(Build.VERSION.SDK_INT>=34)startForeground(NOTIFICATION_ID,notification,ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE);else startForeground(NOTIFICATION_ID,notification);
            PowerManager power=(PowerManager)getSystemService(POWER_SERVICE);wakeLock=power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK,"ChefPocket:HandsfreeCapture");wakeLock.setReferenceCounted(false);wakeLock.acquire(MAX_LISTEN_MS);handler.postDelayed(autoStop,MAX_LISTEN_MS);
        }catch(Exception e){stopSelf();return START_NOT_STICKY;}
        starting=true;stopping=false;int generation=++startGeneration;sendState("Preparing offline voice model");
        new Thread(()->startRecognizer(generation),"chef-vosk-start").start();
        return START_NOT_STICKY;
    }
    private void startRecognizer(int generation){Model loaded=null;Recognizer recognizer=null;SpeechService speech=null;try{
        File path=new File(getFilesDir(),"vosk-model-en-us-0.15");
        if(!new File(path,"model.ready").exists()){copyAssets("model-en-us",path);if(!new File(path,"model.ready").createNewFile())throw new IllegalStateException("Could not finish offline model setup.");}
        if(!new File(path,"am/final.mdl").exists())throw new IllegalStateException("Offline speech model is missing. Reinstall Chef Pocket with its model files.");
        loaded=new Model(path.getAbsolutePath());recognizer=new Recognizer(loaded,16000.0f);speech=new SpeechService(recognizer,16000.0f);
        synchronized(this){if(stopping||generation!=startGeneration){speech.stop();speech.shutdown();recognizer.close();loaded.close();return;}model=loaded;offlineRecognizer=recognizer;speechService=speech;if(!speech.startListening(this))throw new IllegalStateException("Microphone could not start. Stop other recording apps and try again.");running=true;starting=false;}
        handler.post(()->{if(!stopping){setNotice("Listening for “hey chef” · auto-stops in 12 hours");sendState("Listening for hey chef · offline");handler.removeCallbacks(relayRetry);handler.postDelayed(relayRetry,30_000);if(manualArmPending){manualArmPending=false;armManualCapture();}}});
    }catch(Exception e){if(speech!=null){try{speech.stop();speech.shutdown();}catch(Exception ignored){}}if(recognizer!=null){try{recognizer.close();}catch(Exception ignored){}}if(loaded!=null){try{loaded.close();}catch(Exception ignored){}}final SpeechService failedSpeech=speech;final Model failedModel=loaded;final Recognizer failedRecognizer=recognizer;final String failure=e.getMessage();handler.post(()->{synchronized(this){starting=false;running=false;if(speechService==failedSpeech)speechService=null;if(model==failedModel)model=null;if(offlineRecognizer==failedRecognizer)offlineRecognizer=null;}if(!stopping){sendState(failure==null?"Could not start offline listening.":failure);stopSelf();}});}}
    private void copyAssets(String assetPath,File target)throws Exception {
        String[] children=getAssets().list(assetPath);if(children==null||children.length==0){try(InputStream in=getAssets().open(assetPath);FileOutputStream out=new FileOutputStream(target)){byte[] b=new byte[8192];int n;while((n=in.read(b))!=-1)out.write(b,0,n);}return;}
        if(!target.exists()&&!target.mkdirs())throw new IllegalStateException("Cannot prepare offline speech model.");
        for(String child:children)copyAssets(assetPath+"/"+child,new File(target,child));
    }
    @Override public void onResult(String hypothesis){handler.post(()->processHypothesis(hypothesis));}
    @Override public void onPartialResult(String hypothesis){handler.post(()->noteSpeechActivity(hypothesis));}
    @Override public void onFinalResult(String hypothesis){handler.post(()->{processHypothesis(hypothesis);stopSelf();});}
    @Override public void onError(Exception error){handler.post(()->{running=false;starting=false;sendState("Offline speech recognition stopped. Reopen Chef Pocket to try again.");speakFeedback("Chef Pocket voice capture stopped.");stopSelf();});}
    @Override public void onTimeout(){handler.post(()->{running=false;starting=false;sendState("Offline speech recognition timed out. Reopen Chef Pocket to try again.");speakFeedback("Chef Pocket voice capture timed out.");stopSelf();});}
    private void processHypothesis(String json){if(stopping||!running)return;try{
        String text=new JSONObject(json).optString("text","").trim();if(text.isEmpty())return;
        long now=android.os.SystemClock.elapsedRealtime();if(text.equals(lastUtterance)&&now-lastUtteranceAt<1200)return;lastUtterance=text;lastUtteranceAt=now;
        if(pendingCommand!=null){if(text.matches("(?i)(cancel|never mind|nevermind)")){cancelPendingCapture();return;}appendCommand(text);return;}
        WakePhraseMachine.Result result=machine.accept(text,now);
        if(result.kind==WakePhraseMachine.ResultKind.LISTENING){pendingCommand=null;handler.removeCallbacks(settleCapture);handler.removeCallbacks(deadlineCheck);handler.post(deadlineCheck);setNotice("Wake phrase heard · ready for a to-do or thought");sendState("Wake phrase heard · say your capture within 15 seconds");if(!wakeFeedbackSpoken){speakFeedback("I'm listening.");wakeFeedbackSpoken=true;}wakeAcknowledged=true;}
        else if(result.kind==WakePhraseMachine.ResultKind.CAPTURE){wakeAcknowledged=false;wakeFeedbackSpoken=false;pendingCommand=result.text;pendingStartedAt=android.os.SystemClock.elapsedRealtime();handler.removeCallbacks(settleCapture);handler.removeCallbacks(captureTimeout);handler.postDelayed(settleCapture,3000);handler.postDelayed(captureTimeout,45_000);setNotice("Saving after a 3 second pause · tap Stop to end");sendState("Capture heard · waiting for a 3 second pause");if(machine.mode()==WakePhraseMachine.Mode.WAKE)handler.removeCallbacks(deadlineCheck);}
        else if(result.kind==WakePhraseMachine.ResultKind.TIMEOUT){wakeAcknowledged=false;wakeFeedbackSpoken=false;pendingCommand=null;handler.removeCallbacks(settleCapture);handler.removeCallbacks(deadlineCheck);setNotice("Listening for “hey chef”");sendState("Command window ended · listening for hey chef");speakFeedback("I didn't hear a capture. Say hey chef again.");}
    }catch(Exception ignored){}}
    private void cancelPendingCapture(){pendingCommand=null;wakeAcknowledged=false;wakeFeedbackSpoken=false;handler.removeCallbacks(settleCapture);handler.removeCallbacks(captureTimeout);handler.removeCallbacks(deadlineCheck);machine.reset();setNotice("Capture canceled · listening for “hey chef”");sendState("Capture canceled · listening for hey chef");speakFeedback("Okay, capture canceled.");}
    private void noteSpeechActivity(String json){if(stopping||!running)return;try{String partial=new JSONObject(json).optString("partial","").trim();if(partial.isEmpty())return;long now=android.os.SystemClock.elapsedRealtime();if(pendingCommand==null){boolean wake=machine.observePartialWake(partial,now);if(wake){if(!wakeAcknowledged){wakeAcknowledged=true;setNotice("Wake phrase recognized · say your capture");sendState("Wake phrase recognized · say your capture");handler.removeCallbacks(deadlineCheck);handler.post(deadlineCheck);}}else if(now-lastPartialStatusAt>3000){lastPartialStatusAt=now;setNotice("Speech detected on device · waiting for hey chef");sendState("Speech detected locally · wake phrase not recognized");}}else if(!pendingCommand.isEmpty()){handler.removeCallbacks(settleCapture);long remaining=Math.max(0,45_000-(now-pendingStartedAt));if(remaining>0)handler.postDelayed(settleCapture,Math.min(3000,remaining));}}catch(Exception ignored){}}
    private void armManualCapture(){if(!running||pendingCommand!=null){sendState("Finish or cancel the current voice capture first");return;}machine.reset();wakeAcknowledged=false;wakeFeedbackSpoken=false;pendingCommand="";pendingStartedAt=android.os.SystemClock.elapsedRealtime();handler.removeCallbacks(deadlineCheck);handler.removeCallbacks(settleCapture);handler.removeCallbacks(captureTimeout);handler.postDelayed(captureTimeout,20_000);setNotice("Talk now · say one to-do or thought within 20 seconds");sendState("Talk now · say one to-do or thought within 20 seconds");}
    private void appendCommand(String text){int count=pendingCommand.codePointCount(0,pendingCommand.length())+1+text.codePointCount(0,text.length());if(count>500){pendingCommand=null;handler.removeCallbacks(settleCapture);handler.removeCallbacks(captureTimeout);handler.removeCallbacks(deadlineCheck);machine.reset();sendState("Capture is longer than 500 characters. Please say hey chef and try a shorter capture.");setNotice("Capture too long · listening for “hey chef”");speakFeedback("That capture is too long. Try a shorter one.");return;}pendingCommand=pendingCommand+" "+text;handler.removeCallbacks(settleCapture);long remaining=Math.max(0,45_000-(android.os.SystemClock.elapsedRealtime()-pendingStartedAt));if(remaining>0)handler.postDelayed(settleCapture,Math.min(3000,remaining));setNotice("Waiting for a 3 second pause · tap Stop to end");}
    private void saveCapture(String transcript){try{
        String now=java.time.Instant.now().toString();PocketStore.Item item;
        if(transcript.toLowerCase(java.util.Locale.ROOT).contains("calendar")){CalendarParser.Result calendar=CalendarParser.parse(transcript,java.time.ZoneId.systemDefault());org.json.JSONObject req=new org.json.JSONObject();req.put("startAt",calendar.startAt);req.put("endAt",calendar.endAt);req.put("allDay",calendar.allDay);req.put("timeZone",calendar.timeZone);item=new PocketStore.Item(java.util.UUID.randomUUID().toString().toLowerCase(java.util.Locale.ROOT),"calendar",calendar.title,false,now,now,req);}
        else {CaptureParser.Capture parsed=CaptureParser.parse(transcript,"todo");item=new PocketStore.Item(java.util.UUID.randomUUID().toString().toLowerCase(java.util.Locale.ROOT),parsed.kind,parsed.text,false,now,now);}
        String token=PocketStore.readToken(this);PocketStore store=new PocketStore(this);store.save(item,token);boolean added=false,calendarAddFailed=false;if(item.kind.equals("calendar")){try{added=CalendarExecutor.addIfConfigured(this,store,item);}catch(Exception ignored){calendarAddFailed=true;}}
        if(item.kind.equals("todo")){sendState("Saved on this phone · syncing when paired and online");speakFeedback("Saved to your to-do list.");}
        else if(item.kind.equals("thought")){sendState("Saved on this phone · syncing when paired and online");speakFeedback("Saved to your thoughts.");}
        else if(added){sendState("Calendar event added on this phone");speakFeedback("Calendar event added on this phone.");}
        else if(calendarAddFailed){sendState("Calendar request saved on this phone · Android could not add it yet");speakFeedback("Calendar request saved. Chef Pocket could not add it yet.");}
        else{sendState("Calendar request saved on this phone · choose a calendar to add it");speakFeedback("Calendar request saved. Choose a calendar in Chef Pocket.");}
        RelaySync.request(this);setNotice("Listening for “hey chef” · last capture saved");
    }catch(Exception e){sendState(e.getMessage()==null?"Could not save this capture.":e.getMessage());setNotice("Listening for “hey chef” · capture needs a clearer phrase");speakFeedback("I couldn't save that. Try again in Chef Pocket.");}}
    private void speakFeedback(String text){if(Looper.myLooper()!=Looper.getMainLooper()){handler.post(()->speakFeedback(text));return;}if(stopping)return;if(phoneVoice==null)phoneVoice=new PhoneVoice(this,this::sendState);phoneVoice.speak(text);}
    private void setNotice(String message){try{((NotificationManager)getSystemService(NOTIFICATION_SERVICE)).notify(NOTIFICATION_ID,notification(message));}catch(Exception ignored){}}
    private Notification notification(String message){Intent stop=new Intent(this,WakeCaptureService.class).setAction(ACTION_STOP);PendingIntent action=PendingIntent.getService(this,7302,stop,PendingIntent.FLAG_UPDATE_CURRENT|PendingIntent.FLAG_IMMUTABLE);PendingIntent open=PendingIntent.getActivity(this,7303,new Intent(this,MainActivity.class),PendingIntent.FLAG_UPDATE_CURRENT|PendingIntent.FLAG_IMMUTABLE);
        Notification.Builder b=new Notification.Builder(this,CHANNEL);b.setSmallIcon(android.R.drawable.ic_btn_speak_now).setContentTitle("Chef Pocket is listening").setContentText(message).setOngoing(true).setCategory(Notification.CATEGORY_SERVICE).setContentIntent(open).addAction(android.R.drawable.ic_media_pause,"Stop",action);return b.build();}
    private void createChannel(){NotificationChannel c=new NotificationChannel(CHANNEL,"Chef voice capture",NotificationManager.IMPORTANCE_LOW);c.setDescription("Shows while the explicitly enabled offline wake phrase listener is active.");((NotificationManager)getSystemService(NOTIFICATION_SERVICE)).createNotificationChannel(c);}
    private void sendState(String value){Intent i=new Intent(ACTION_STATE);i.setPackage(getPackageName());i.putExtra(EXTRA_STATE,value);sendBroadcast(i);}
    @Override public void onDestroy(){synchronized(this){stopping=true;startGeneration++;starting=false;running=false;}handler.removeCallbacksAndMessages(null);pendingCommand=null;if(speechService!=null){try{speechService.stop();speechService.shutdown();}catch(Exception ignored){}speechService=null;}if(offlineRecognizer!=null){try{offlineRecognizer.close();}catch(Exception ignored){}offlineRecognizer=null;}if(model!=null){try{model.close();}catch(Exception ignored){}model=null;}if(phoneVoice!=null){phoneVoice.close();phoneVoice=null;}if(wakeLock!=null&&wakeLock.isHeld()){try{wakeLock.release();}catch(Exception ignored){}wakeLock=null;}stopForeground(STOP_FOREGROUND_REMOVE);sendState("Voice capture stopped");super.onDestroy();}
    @Override public IBinder onBind(Intent intent){return null;}
}
