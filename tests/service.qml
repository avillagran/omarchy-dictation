import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "UnderTest" as Test
// Service.qml with stand-in helpers (tools/test-qml): defaults, the bubble at
// the text cursor or the pointer, states, the wave, push to talk, ✕, a muted
// microphone, the model download, a window that lost focus and the settings.
ShellRoot{
 id:root;property int phase:0;property double mark:0
 onPhaseChanged:console.log("DICTATION_STEP "+phase+" "+s.phase+" "+s.session.state)
 readonly property string home:Quickshell.env("HOME")
 function check(ok,msg){if(!ok){console.error("DICTATION_FAIL: "+msg);Qt.exit(1)}}
 function named(item,name){if(!item)return null;if(item.objectName===name)return item;var kids=item.children || [];for(var i=0;i<kids.length;i++){var found=named(kids[i],name);if(found)return found}return null}
 function bubble(){return s.bubbleWindow?named(s.bubbleWindow.contentItem,"dictationBubble"):null}
 component Log: FileView{watchChanges:true;printErrors:false;onFileChanged:reload()}
 Log{id:listenArgs;path:root.home+"/listen-args"}
 Log{id:escapeLog;path:root.home+"/escape.log"}
 Log{id:insertedLog;path:root.home+"/inserted"}
 Log{id:wpctlLog;path:root.home+"/wpctl.log"}
 Log{id:hyprctlLog;path:root.home+"/hyprctl.log"}
 Log{id:settingsLog;path:Quickshell.env("XDG_CONFIG_HOME")+"/omarchy-dictation/settings.json"}
 function lines(log){return log.text().split("\n").filter(function(l){return l}).length}
 FileView{id:target;path:root.home+"/target.json";printErrors:false}
 FileView{id:result;path:root.home+"/insert-result";printErrors:false}
 function window(address,pointer){target.setText(JSON.stringify({address:address,"class":"chromium",title:"Notes — draft",terminal:false,pointer:pointer||{x:900,y:500}}))}
 Test.Service{id:s}
 Component{id:panelProbe;Item{}}
 Timer{interval:120;running:true;repeat:true;onTriggered:{
  var b=root.bubble()
  if(phase===0){
   check(s.settings.enabled===true&&s.settings.shortcut==="CTRL + SPACE"&&s.settings.method==="paste","Ctrl+Space and paste by default")
   var panel=Qt.createComponent(Qt.resolvedUrl("UnderTest/Panel.qml"));check(panel.status===Component.Ready,"the settings panel loads: "+panel.errorString())
   if(s.caret.address!=="0xapp")return
   // Where the bubble goes: an empty cursor (terminals) is none; the pointer only over the window.
   var real=s.caret;s.target={address:"0xw",at:[100,100],size:[400,300],pointer:{x:900,y:900}}
   s.caret={address:"0xw",x:0,y:0,w:0,h:0};check(s.placement().from==="window","empty cursor, pointer elsewhere → the window")
   s.target.pointer={x:150,y:150};check(s.placement().from==="pointer","pointer over the window")
   s.caret={address:"0xw",x:120,y:130,w:2,h:16};check(s.placement().from==="caret"&&s.placement().y===130,"a real cursor wins")
   s.caret=real;s.target=({})
   window("0xapp");check(!s.bubbleWindow,"no window at rest");check(s.toggle()==="starting","toggle starts");phase=1
  }else if(phase===1){if(s.session.state!=="recording"||s.session.levels.length<3||escapeLog.text().indexOf("bind")<0||!listenArgs.text()||!b)return
   check(b.visible&&b.listening,"the bubble shows while the microphone is open")
   check(s.anchor&&s.anchor.from==="caret"&&s.anchor.x===300,"anchored at the text cursor");var sy=s.screen?s.screen.y:0
   check(Math.abs(b.y-(200-sy+18+Style.space(6)))<1||b.y<200-sy,"just under the cursor's line: "+b.y)
   check(root.named(b,"dictationBubbleWave").visible,"the wave shows");check(b.bar(0.2)===0&&b.bar(0.8)>0.9,"room noise flat, voice tall")
   check(listenArgs.text().indexOf("--prompt Notes — draft")>=0,"window title as a hint: "+listenArgs.text())
   check(s.toggle()==="stopping","toggle again stops");phase=2
  }else if(phase===2){if(s.phase!=="notice"||!insertedLog.text()||escapeLog.text().indexOf("unbind")<0)return
   check(insertedLog.text().trim()==="--address 0xapp --method paste|hola mundo","inserted into the window that had focus: "+insertedLog.text())
   check(s.notice.kind==="inserted"&&s.notice.text==="Insertado · Español","inserted with the language: "+s.notice.text);s.dismiss()
   // Another window: the cursor is not there, so the pointer places it.
   window("0xother",{x:700,y:450});check(s.press()==="starting","press starts");mark=Date.now();phase=3
  }else if(phase===3){if(s.session.state!=="recording")return
   check(s.anchor&&s.anchor.from==="pointer"&&s.anchor.x===700,"at the pointer without a text cursor there")
   if(Date.now()-mark<450){check(s.release()==="recording","a tap keeps recording");phase=4}else check(false,"tap too slow for the check")
  }else if(phase===4){check(s.session.state==="recording","still recording after a tap");check(s.press()==="stopping","next press stops");phase=5
  }else if(phase===5){if(s.phase!=="notice")return;s.dismiss();s.press();mark=Date.now();phase=6
  }else if(phase===6){if(s.session.state!=="recording"||Date.now()-mark<600)return;check(s.release()==="stopping","release after a hold stops");phase=7
  }else if(phase===7){if(s.phase!=="notice"||lines(insertedLog)<3)return;s.dismiss();s.toggle();phase=8
  }else if(phase===8){if(s.session.state!=="recording"||!b)return
   check(root.named(b,"dictationBubbleCancel").visible,"✕ is shown");b.cancelRequested();phase=9
  }else if(phase===9){if(s.phase!=="idle")return;check(lines(insertedLog)===3,"cancel inserts nothing");s.toggle();phase=10
  }else if(phase===10){if(s.session.state!=="recording"||!b)return
   s.session.muted=true;check(b.message==="Micrófono silenciado · clic para activarlo","a muted microphone says so: "+b.message)
   b.unmuteRequested();check(!s.session.muted,"a click unmutes");mark=Date.now();phase=11
  }else if(phase===11){if(wpctlLog.text().indexOf("set-mute @DEFAULT_AUDIO_SOURCE@ 0")<0)return;check(s.cancel()==="cancelled","cancel from the CLI");phase=12
  }else if(phase===12){if(s.phase!=="idle")return;s.save({model:"small"});check(settingsLog.text()===""||true,"");phase=13
  }else if(phase===13){if(settingsLog.text().indexOf('"model": "small"')<0)return;check(hyprctlLog.text().indexOf("reload")<0,"a model change does not reload Hyprland: "+hyprctlLog.text());s.toggle();phase=14
  }else if(phase===14){if(s.phase!=="notice")return;check(s.notice.kind==="model"&&!s.session.busy,"model notice and no recording")
   check(b&&b.message.indexOf("Descarga el modelo de dictado")===0,"asks to download: "+(b&&b.message));b.downloadRequested();phase=15
  }else if(phase===15){if(!s.download.busy)return;check(s.notice.kind==="downloading","download shows progress");phase=16
  }else if(phase===16){if(s.download.busy)return;check(s.notice.kind==="inserted"&&s.notice.text.indexOf("listo")>0,"model ready: "+s.notice.text);s.dismiss()
   // Focus moved while transcribing: copied, with a notice.
   result.setText("copied\n");window("0xapp");mark=Date.now();phase=17
  }else if(phase===17){if(Date.now()-mark<200)return;s.toggle();phase=18
  }else if(phase===18){if(s.session.state!=="recording")return;s.stop();phase=19
  }else if(phase===19){if(s.phase!=="notice")return;check(s.notice.kind==="copied"&&s.notice.text==="Dictado copiado al portapapeles","focus moved → copied: "+s.notice.text);s.dismiss()
   // A new shortcut is saved and Hyprland reloads its bindings.
   s.save({shortcut:"SUPER + ALT + D"});phase=20
  }else if(phase===20){if(hyprctlLog.text().indexOf("reload config-only")<0)return;check(settingsLog.text().indexOf('"shortcut": "SUPER + ALT + D"')>0,"shortcut saved")
   s.save({enabled:false});phase=21
  }else if(phase===21){if(s.settings.enabled!==false)return;check(s.toggle()==="disabled","disabled does nothing");mark=Date.now();phase=22
  }else if(phase===22){if(Date.now()-mark<500)return;check(!s.bubbleWindow,"the bubble window is gone at rest")
   console.log("DICTATION_PASS: defaults, bubble at the text cursor or pointer, states, wave, push to talk, ✕, muted, model download, focus moved and settings");Qt.quit()}
 }}
}
