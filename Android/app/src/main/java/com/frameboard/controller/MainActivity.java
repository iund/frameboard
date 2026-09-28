package com.frameboard.controller;

import android.app.*;
import android.content.*;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.text.InputType;
import android.view.*;
import android.widget.*;
import com.google.zxing.integration.android.IntentIntegrator;
import com.google.zxing.integration.android.IntentResult;
import org.json.*;
import java.util.List;

public final class MainActivity extends Activity implements FrameboardView.Commands {
    private static final int INK=0xffe4edf7, MUTED=0xff9cacc1, ACCENT=0xff68d8d0, PANEL=0xdd16212e;
    private FrameboardView stage;
    private FrameboardConnection connection;
    private TextView status;
    private Button drawButton,eraseButton,clearButton,resetButton;
    private FrameboardView.Tool selectedTool=FrameboardView.Tool.PEN;

    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        getWindow().setStatusBarColor(Color.TRANSPARENT);getWindow().setNavigationBarColor(Color.TRANSPARENT);
        getWindow().setDecorFitsSystemWindows(false);
        FrameLayout root=new FrameLayout(this);root.setBackgroundColor(0xff0b1119);
        stage=new FrameboardView(this,this);root.addView(stage,new FrameLayout.LayoutParams(-1,-1));
        status=label("Open the macOS app and scan its QR code to connect",14,INK);
        status.setGravity(Gravity.CENTER);status.setPadding(dp(14),dp(8),dp(14),dp(8));status.setBackground(oval(0xcc16212e));
        FrameLayout.LayoutParams statusParams=new FrameLayout.LayoutParams(-2,-2,Gravity.TOP|Gravity.CENTER_HORIZONTAL);
        statusParams.setMargins(dp(16),dp(16),dp(16),0);root.addView(status,statusParams);

        LinearLayout tools=new LinearLayout(this);tools.setOrientation(LinearLayout.VERTICAL);
        drawButton=symbolButton("✎","Draw",v->selectTool(FrameboardView.Tool.PEN));tools.addView(drawButton);
        eraseButton=symbolButton("⌫","Erase",v->selectTool(FrameboardView.Tool.ERASER));tools.addView(eraseButton);
        clearButton=symbolButton("⊘","Clear all drawings",v->new AlertDialog.Builder(this).setTitle("Clear all ink?")
            .setNegativeButton("Cancel",null).setPositiveButton("Clear",(d,w)->stage.clearInk()).show());tools.addView(clearButton);
        resetButton=symbolButton("↺","Reset camera position",v->stage.resetLayout());tools.addView(resetButton);
        FrameLayout.LayoutParams toolParams=new FrameLayout.LayoutParams(-2,-2,Gravity.BOTTOM|Gravity.START);
        toolParams.setMargins(dp(14),0,0,dp(14));root.addView(tools,toolParams);setContentView(root);
        WindowInsetsController bars=getWindow().getDecorView().getWindowInsetsController();
        if(bars!=null){bars.hide(WindowInsets.Type.systemBars());bars.setSystemBarsBehavior(WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);}

        connection=new FrameboardConnection(new FrameboardConnection.Listener() {
            public void state(String title,String detail,boolean live) {
                stage.setConnected(live);status.setText(title+(detail.isEmpty()?"":"\n"+detail));status.setVisibility(live?View.GONE:View.VISIBLE);updateControls(live);
            }
            public void connectionFailed(String detail){showConnectionOptions(detail);}
            public void preview(android.graphics.Bitmap image){stage.setPreview(image);}
            public void layout(float x,float y,float w,float h){stage.setLayout(x,y,w,h);}
        });
        stage.setTool(selectedTool);updateControls(false);stage.post(this::connectSavedOrScan);
    }
    private int dp(float n){return(int)(n*getResources().getDisplayMetrics().density+.5f);}
    private TextView label(String text,int size,int color){TextView view=new TextView(this);view.setText(text);view.setTextSize(size);view.setTextColor(color);return view;}
    private GradientDrawable oval(int color){GradientDrawable shape=new GradientDrawable();shape.setShape(GradientDrawable.OVAL);shape.setColor(color);return shape;}
    private Button symbolButton(String symbol,String description,View.OnClickListener click){
        Button button=new Button(this);button.setText(symbol);button.setTextSize(19);button.setTextColor(INK);button.setContentDescription(description);
        button.setAllCaps(false);button.setPadding(0,0,0,0);button.setMinWidth(0);button.setMinHeight(0);button.setBackground(oval(PANEL));button.setOnClickListener(click);
        LinearLayout.LayoutParams params=new LinearLayout.LayoutParams(dp(50),dp(50));params.setMargins(0,dp(3),0,dp(3));button.setLayoutParams(params);return button;
    }
    private void selectTool(FrameboardView.Tool tool){selectedTool=tool;stage.setTool(tool);updateControls(true);}
    private void updateControls(boolean usable){
        for(Button button:new Button[]{drawButton,eraseButton,clearButton,resetButton}){button.setEnabled(usable);button.setAlpha(usable?1:.4f);}
        drawButton.setBackground(oval(selectedTool==FrameboardView.Tool.PEN?ACCENT:PANEL));eraseButton.setBackground(oval(selectedTool==FrameboardView.Tool.ERASER?ACCENT:PANEL));
        drawButton.setTextColor(selectedTool==FrameboardView.Tool.PEN?0xff092c31:INK);eraseButton.setTextColor(selectedTool==FrameboardView.Tool.ERASER?0xff092c31:INK);
    }
    private void resetConnection(){connection.stop();stage.setConnected(false);status.setVisibility(View.VISIBLE);updateControls(false);}
    private void scanPairingCode(){
        resetConnection();status.setText("Open the macOS app and scan its QR code to connect");
        new IntentIntegrator(this).setDesiredBarcodeFormats(java.util.Collections.singleton("QR_CODE"))
            .setPrompt("Open the macOS app and scan its QR code to connect").setBeepEnabled(false).setOrientationLocked(false).initiateScan();
    }
    private void connectSavedOrScan(){
        android.content.SharedPreferences trust=getSharedPreferences("trusted-mac",MODE_PRIVATE);
        String saved=trust.getString("pairing-code",null),identity=trust.getString("identity",null);
        if(saved!=null)try{
            PairingCode code=PairingCode.verify(saved);
            if(code.identity.equals(identity)){connect(code);return;}
        }catch(Exception ignored){}
        trust.edit().remove("pairing-code").apply();scanPairingCode();
    }
    @Override protected void onActivityResult(int requestCode,int resultCode,Intent data){
        IntentResult result=IntentIntegrator.parseActivityResult(requestCode,resultCode,data);
        if(result==null){super.onActivityResult(requestCode,resultCode,data);return;}
        if(result.getContents()==null){showConnectionOptions("QR scan cancelled.");return;}
        try{acceptPairingCode(PairingCode.verify(result.getContents()));}
        catch(Exception e){showConnectionOptions(e.getMessage()==null?"That QR code could not be verified.":e.getMessage());}
    }
    private void acceptPairingCode(PairingCode code){
        android.content.SharedPreferences trust=getSharedPreferences("trusted-mac",MODE_PRIVATE);String trusted=trust.getString("identity",null);
        if(code.identity.equals(trusted)){trust.edit().putString("pairing-code",code.payload).apply();connect(code);return;}
        boolean replacing=trusted!=null;
        new AlertDialog.Builder(this).setTitle(replacing?"Different Mac identity":"Trust this Mac?")
            .setMessage((replacing?"Verify the identity shown on the new Mac before replacing the saved one.\n\n":"Verify this identity matches the one beside the QR code on your Mac.\n\n")+code.fingerprint)
            .setNegativeButton("Cancel",null).setPositiveButton(replacing?"Replace trusted Mac":"Trust and connect",(dialog,which)->{trust.edit().putString("identity",code.identity).putString("pairing-code",code.payload).apply();connect(code);}).show();
    }
    private void connect(PairingCode code){status.setText("Connecting securely…");connection.manual(code.host,code.port,code.secret);}
    private void showConnectionOptions(String reason){
        if(isFinishing()||isDestroyed())return;status.setText(reason);
        new AlertDialog.Builder(this).setTitle("Connect to Frameboard").setMessage(reason)
            .setItems(new String[]{"Scan QR code","Enter LAN details","Cancel"},(dialog,which)->{if(which==0)scanPairingCode();else if(which==1)manual();}).show();
    }
    private void manual(){
        LinearLayout form=new LinearLayout(this);form.setOrientation(LinearLayout.VERTICAL);form.setPadding(dp(24),dp(8),dp(24),0);
        form.addView(label("Enter the details shown in Frameboard on the Mac.",14,MUTED));android.content.SharedPreferences prefs=getPreferences(MODE_PRIVATE);
        EditText host=field(form,"Mac address",prefs.getString("host",""),InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_VARIATION_URI);
        EditText port=field(form,"Port",prefs.getString("port",""),InputType.TYPE_CLASS_NUMBER);
        EditText token=field(form,"Session secret","",InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD);
        ScrollView scroll=new ScrollView(this);scroll.addView(form);
        AlertDialog dialog=new AlertDialog.Builder(this).setTitle("Manual LAN connection").setView(scroll).setNegativeButton("Cancel",null).setPositiveButton("Connect",null).create();
        dialog.setOnShowListener(d->dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v->{
            String address=host.getText().toString().trim(),secret=token.getText().toString().trim();int number;
            if(address.isEmpty()){host.setError("Enter the Mac address");return;}
            try{number=Integer.parseInt(port.getText().toString());if(number<1||number>65535)throw new NumberFormatException();}catch(NumberFormatException e){port.setError("Use a port from 1 to 65535");return;}
            try{java.util.UUID.fromString(secret);}catch(IllegalArgumentException e){token.setError("Enter the complete session secret");return;}
            prefs.edit().putString("host",address).putString("port",Integer.toString(number)).apply();resetConnection();connection.manual(address,number,secret);dialog.dismiss();
        }));dialog.show();
    }
    private EditText field(LinearLayout form,String hint,String value,int type){
        EditText field=new EditText(this);field.setHint(hint);field.setText(value);field.setTextColor(INK);field.setHintTextColor(MUTED);field.setSingleLine(true);field.setInputType(type);
        form.addView(field,new LinearLayout.LayoutParams(-1,dp(56)));return field;
    }
    private void send(JSONObject message){connection.send(message);}
    @Override public void layout(float x,float y,float w,float h){try{send(new JSONObject().put("type","layout").put("x",x).put("y",y).put("w",w).put("h",h));}catch(JSONException ignored){}}
    @Override public void stroke(List<float[]> points){try{JSONArray array=new JSONArray();for(float[] point:points)array.put(new JSONArray().put(point[0]).put(point[1]));send(new JSONObject().put("type","stroke").put("points",array));}catch(JSONException ignored){}}
    @Override public void erase(float x,float y,float radius){try{send(new JSONObject().put("type","erase").put("x",x).put("y",y).put("radius",radius));}catch(JSONException ignored){}}
    @Override public void clear(){try{send(new JSONObject().put("type","clear"));}catch(JSONException ignored){}}
    @Override protected void onDestroy(){if(connection!=null)connection.close();super.onDestroy();}
}
