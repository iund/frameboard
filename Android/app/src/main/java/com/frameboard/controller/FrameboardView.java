package com.frameboard.controller;

import android.content.Context;
import android.graphics.*;
import android.view.MotionEvent;
import android.view.View;
import java.util.ArrayList;
import java.util.List;

/** Coordinates always describe the full 16:9 output, never tablet pixels. */
public final class FrameboardView extends View {
    public interface Commands {
        void layout(float x,float y,float w,float h);
        void stroke(List<float[]> points);
        void erase(float x,float y,float radius);
        void clear();
    }
    public enum Tool { MOVE, PEN, ERASER }
    private final Paint paint=new Paint(Paint.ANTI_ALIAS_FLAG | Paint.FILTER_BITMAP_FLAG);
    private final RectF stage=new RectF();
    private final List<float[]> pending=new ArrayList<>();
    private final List<List<float[]>> practiceInk=new ArrayList<>();
    private final Commands commands;
    private Bitmap preview;
    private Tool tool=Tool.PEN;
    private boolean practice, connected, gesture, movingVideo;
    private float x=0,y=0,w=1,h=1,lastX,lastY,lastSpan;
    private String placeholder="Your Mac's camera will appear here";

    public FrameboardView(Context context,Commands commands) {
        super(context);this.commands=commands;setBackgroundColor(0xff0b1119);
        setContentDescription("Camera stage. Use Move to drag or pinch the camera. Use Pen to draw on the blackboard.");
        setFocusable(true);
    }
    public void setTool(Tool value) { tool=value;pending.clear();invalidate(); }
    public void setConnected(boolean value) { connected=value;gesture=false;pending.clear();invalidate(); }
    public void setPractice(boolean value) {
        practice=value;preview=null;practiceInk.clear();pending.clear();
        x=y=0;w=h=1;invalidate();
    }
    public boolean isPractice() { return practice; }
    public void setPlaceholder(String text) { placeholder=text;invalidate(); }
    public void setPreview(Bitmap image) { preview=image;invalidate(); }
    public void setLayout(float left,float top,float width,float height) {
        if(!Float.isFinite(left) || !Float.isFinite(top) || !Float.isFinite(width) || !Float.isFinite(height)
                || left<0 || top<0 || width<.1f || height<.1f || left+width>1.001f || top+height>1.001f)return;
        x=left;y=top;w=width;h=height;invalidate();
    }
    public void preset(boolean full) {
        if(!connected && !practice)return;
        x=full?0:.54f;y=full?0:.08f;w=h=full?1:.4f;
        commands.layout(x,y,w,h);invalidate();
    }
    public void resetLayout() { preset(false); }
    public void clearInk() { practiceInk.clear();pending.clear();commands.clear();invalidate(); }
    private float dp(float n) { return n*getResources().getDisplayMetrics().density; }
    private float nx(float px) { return Math.max(0,Math.min(1,(px-stage.left)/stage.width())); }
    private float ny(float py) { return Math.max(0,Math.min(1,(py-stage.top)/stage.height())); }
    private RectF video() { return new RectF(stage.left+x*stage.width(),stage.top+y*stage.height(),stage.left+(x+w)*stage.width(),stage.top+(y+h)*stage.height()); }
    @Override protected void onSizeChanged(int width,int height,int oldWidth,int oldHeight) {
        float sw=Math.max(1,Math.min(width,height*16/9f));
        float sh=sw*9/16f;
        stage.set((width-sw)/2,(height-sh)/2,(width+sw)/2,(height+sh)/2);
    }
    private void text(Canvas c,String text,float cx,float cy,float size,int color) {
        paint.setStyle(Paint.Style.FILL);paint.setTextAlign(Paint.Align.CENTER);paint.setTextSize(dp(size));paint.setColor(color);
        c.drawText(text,cx,cy,paint);
    }
    @Override protected void onDraw(Canvas c) {
        super.onDraw(c);
        paint.setStyle(Paint.Style.FILL);paint.setColor(Color.BLACK);c.drawRoundRect(stage,dp(8),dp(8),paint);
        int save=c.save();c.clipRect(stage);
        if(practice) {
            for(List<float[]> line:practiceInk)drawLine(c,line);
            RectF camera=video();
            paint.setStyle(Paint.Style.FILL);paint.setShader(new LinearGradient(camera.left,camera.top,camera.right,camera.bottom,0xff173b55,0xff217a82,Shader.TileMode.CLAMP));
            c.drawRect(camera,paint);paint.setShader(null);
            paint.setColor(0xff74c7cd);c.drawCircle(camera.centerX(),camera.centerY()-camera.height()*.12f,camera.height()*.12f,paint);
            c.drawOval(new RectF(camera.centerX()-camera.width()*.16f,camera.centerY()+camera.height()*.03f,camera.centerX()+camera.width()*.16f,camera.bottom+camera.height()*.15f),paint);
            if(camera.width()>dp(150))text(c,"PRACTICE CAMERA",camera.centerX(),camera.top+dp(28),12,Color.WHITE);
        } else if(preview!=null) {
            paint.setStyle(Paint.Style.FILL);paint.setColor(Color.WHITE);c.drawBitmap(preview,null,stage,paint);
        } else {
            text(c,"FRAMEBOARD",stage.centerX(),stage.centerY()-dp(20),24,0xff68d8d0);
            text(c,placeholder,stage.centerX(),stage.centerY()+dp(16),15,0xffbac6d5);
            text(c,"Connect a Mac or try Practice to explore the controls",stage.centerX(),stage.centerY()+dp(44),13,0xff8190a5);
        }
        drawLine(c,pending);
        if(connected || practice) {
            paint.setStyle(Paint.Style.STROKE);paint.setStrokeWidth(dp(2));paint.setColor(0xff68d8d0);c.drawRect(video(),paint);
        }
        c.restoreToCount(save);
        if(preview!=null && !connected && !practice)text(c,"Disconnected · last received frame",stage.centerX(),stage.top+dp(28),14,0xffffce8a);
    }
    private void drawLine(Canvas c,List<float[]> points) {
        if(points.isEmpty())return;
        paint.setStyle(Paint.Style.STROKE);paint.setColor(Color.WHITE);paint.setStrokeWidth(stage.width()*4/1280f);
        paint.setStrokeCap(Paint.Cap.ROUND);paint.setStrokeJoin(Paint.Join.ROUND);
        Path path=new Path();float[] first=points.get(0);path.moveTo(stage.left+first[0]*stage.width(),stage.top+first[1]*stage.height());
        if(points.size()==1)path.lineTo(stage.left+first[0]*stage.width()+1,stage.top+first[1]*stage.height());
        for(int i=1;i<points.size();i++)path.lineTo(stage.left+points.get(i)[0]*stage.width(),stage.top+points.get(i)[1]*stage.height());
        c.drawPath(path,paint);
    }
    private boolean onVideo(float a,float b) { return a>=x && a<=x+w && b>=y && b<=y+h; }
    private void eraseAt(float a,float b) {
        practiceInk.removeIf(line->line.stream().anyMatch(p->Math.hypot(p[0]-a,p[1]-b)<.025));
        commands.erase(a,b,.025f);invalidate();
    }
    private void commitStroke() {
        if(pending.isEmpty())return;
        List<float[]> line=new ArrayList<>(pending);
        if(practice && practiceInk.size()<1024)practiceInk.add(line);
        commands.stroke(line);pending.clear();
    }
    @Override public boolean performClick() { super.performClick();return true; }
    @Override public boolean onTouchEvent(MotionEvent e) {
        if(!practice && !connected)return true;
        int action=e.getActionMasked();float px=e.getX(),py=e.getY(),a=nx(px),b=ny(py);
        if(action==MotionEvent.ACTION_DOWN) {
            movingVideo=stage.contains(px,py) && onVideo(a,b);
            gesture=movingVideo || stage.contains(px,py);
            if(!gesture)return true;
            getParent().requestDisallowInterceptTouchEvent(true);
            lastX=a;lastY=b;lastSpan=0;
            if(!movingVideo && tool==Tool.PEN)pending.add(new float[]{a,b});
            if(!movingVideo && tool==Tool.ERASER)eraseAt(a,b);
            invalidate();return true;
        }
        if(!gesture)return true;
        if(action==MotionEvent.ACTION_POINTER_DOWN) {
            commitStroke();
            lastSpan=(float)Math.hypot(e.getX(1)-e.getX(0),e.getY(1)-e.getY(0));
        } else if(action==MotionEvent.ACTION_MOVE) {
            if(movingVideo && e.getPointerCount()==2) {
                float span=(float)Math.hypot(e.getX(1)-e.getX(0),e.getY(1)-e.getY(0));
                if(lastSpan>0) {
                    float scale=Math.max(Math.max(.15f/w,.15f/h),Math.min(Math.min(1/w,1/h),span/lastSpan));
                    float nw=w*scale,nh=h*scale;
                    x=Math.max(0,Math.min(1-nw,x+(w-nw)/2));y=Math.max(0,Math.min(1-nh,y+(h-nh)/2));w=nw;h=nh;
                    commands.layout(x,y,w,h);
                }
                lastSpan=span;
            } else if(movingVideo && e.getPointerCount()==1) {
                x=Math.max(0,Math.min(1-w,x+a-lastX));y=Math.max(0,Math.min(1-h,y+b-lastY));commands.layout(x,y,w,h);
            } else if(!movingVideo && tool==Tool.PEN && e.getPointerCount()==1) {
                if(stage.contains(px,py) && !onVideo(a,b)) {
                    if(pending.size()>=4096)commitStroke();
                    pending.add(new float[]{a,b});
                } else commitStroke();
            } else if(!movingVideo && tool==Tool.ERASER && e.getPointerCount()==1 && !onVideo(a,b))eraseAt(a,b);
            lastX=a;lastY=b;
        } else if(action==MotionEvent.ACTION_POINTER_UP) {
            int remaining=e.getActionIndex()==0?1:0;lastX=nx(e.getX(remaining));lastY=ny(e.getY(remaining));lastSpan=0;
        } else if(action==MotionEvent.ACTION_UP || action==MotionEvent.ACTION_CANCEL) {
            if(action==MotionEvent.ACTION_UP) { commitStroke();performClick(); } else pending.clear();
            gesture=false;movingVideo=false;lastSpan=0;getParent().requestDisallowInterceptTouchEvent(false);
        }
        invalidate();return true;
    }
}
