#pragma once

#include <jni.h>


#ifndef _Included_MyJNI
#define _Included_MyJNI
#ifdef __cplusplus
extern "C" {
#endif

//	JNIEXPORT jintArray JNICALL Java_live_thought_jtminer_NativeCDLLCuckooEngine_cuckoo_engine(JNIEnv* env, jobject obj, jintArray blockHeader, jint	jint);


	JNIEXPORT jintArray JNICALL Java_live_thought_jtminer_NativeCDLLCuckooEngine_cuckooengine(JNIEnv* env, jobject obj, jbyteArray byteArray, jbyteArray target_byteArray);


	JNIEXPORT void JNICALL Java_live_thought_jtminer_NativeCDLLCuckooEngine_stop(JNIEnv* env, jobject obj);


#ifdef __cplusplus
}
#endif
#endif


extern int		g_bStop;
extern BYTE*	g_target_data;
extern int		g_target_len;