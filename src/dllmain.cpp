// dllmain.cpp : Defines the entry point for the DLL application.
#include "pch.h"
#include "CCuckooEngine.h"
#include "cuckoo1.h"

BOOL APIENTRY DllMain( HMODULE hModule,
                       DWORD  ul_reason_for_call,
                       LPVOID lpReserved
                     )
{
    switch (ul_reason_for_call)
    {
    case DLL_PROCESS_ATTACH:
    case DLL_THREAD_ATTACH:
    case DLL_THREAD_DETACH:
    case DLL_PROCESS_DETACH:
        break;
    }
    return TRUE;
}
#define C_RETURN_SOLN_DATA_LEN  43 //. 42 + 1(range)

//
int* getIntArray() {
    static int array[C_RETURN_SOLN_DATA_LEN];
    return array;
}

int     g_bStop = 0;
BYTE*   g_target_data = new BYTE[80];
int     g_target_len = 0;

//.
JNIEXPORT jintArray JNICALL Java_live_thought_jtminer_NativeCDLLCuckooEngine_cuckooengine(JNIEnv* env, jobject obj, jbyteArray p_byteArray, jbyteArray target_byteArray)
{
    BYTE    w_BlockHeader[HEADERLEN];
    int     w_BlockHeaderLen = 0;
    int     w_start_nonce = 0;

    jintArray ret = 0;
    jclass thisClass = env->GetObjectClass(obj);

    printf("cuckooengine start --- \n");
    g_bStop = 0;
    // Get the Field ID of the instance variables "number"
    jfieldID fidNumber = env->GetFieldID(thisClass, "block_len", "I");
    jint number = env->GetIntField( obj, fidNumber);

    jfieldID jv_nonce = env->GetFieldID(thisClass, "start_nonce", "I");
    jint start_nonce = env->GetIntField(obj, jv_nonce);
    w_start_nonce = (int)start_nonce;

    // Copy the bytes from Java byte array to C++ buffer
    jsize length = env->GetArrayLength(p_byteArray);
    jbyte* byteArrayElements = env->GetByteArrayElements(p_byteArray, nullptr);
    BYTE* block_header = new BYTE[length];
    memset(block_header, 0x00, sizeof(BYTE) * length);
    memcpy(block_header, byteArrayElements, sizeof(BYTE)* length);
    env->ReleaseByteArrayElements(p_byteArray, byteArrayElements, JNI_ABORT);

 /*   printf("FIRST C_Header --- ");
    for (int i = 0; i < 80; i++) {
        printf("%02X", block_header[i]);
    }
    printf("\n ");*/

    jsize target_length = env->GetArrayLength(target_byteArray);
    jbyte* target_byteArrayElements = env->GetByteArrayElements(target_byteArray, nullptr);
    memset(g_target_data, 0x00, sizeof(BYTE) * 80);
    memcpy(&(g_target_data[32 - target_length]), target_byteArrayElements, sizeof(BYTE) * target_length);
    env->ReleaseByteArrayElements(target_byteArray, target_byteArrayElements, JNI_ABORT);
    g_target_len = (int)target_length;

    w_BlockHeaderLen = (int)length;
    int* soln_data = getIntArray();

    int     w_porf[43];
    for (int i = w_start_nonce; i < w_start_nonce + 500000; i+= 1) {
        int w_Rtn = cuckoo_scanhash((const BYTE*)block_header, i, (uint32_t*)w_porf);
        if (w_Rtn == 0) {
            w_porf[42] = i;
            break;
        }
        if (g_bStop == 1) {
            break;
        }
    }
    jsize soln_data_length = C_RETURN_SOLN_DATA_LEN; // Length of the array
    ret = env->NewIntArray(soln_data_length);
    env->SetIntArrayRegion(ret, 0, soln_data_length, (const jint*)w_porf);

    //if (my_cuckoo_engine(block_header, w_BlockHeaderLen, w_start_nonce, soln_data)) {
    //    jsize soln_data_length = C_RETURN_SOLN_DATA_LEN; // Length of the array
    //    ret = env->NewIntArray(soln_data_length);
    //    env->SetIntArrayRegion(ret, 0, soln_data_length, (const jint*)soln_data);
    //}
    //else {
    //    printf("my_cuckoo_engine -- Faild\n");
    //    jsize soln_data_length = 1; // Length of the array
    //    ret = env->NewIntArray(1);
    //    env->SetIntArrayRegion(ret, 0, 1, (const jint*)soln_data);
    //}

    delete[] block_header;
    //. 
    return ret;
}

JNIEXPORT void JNICALL Java_live_thought_jtminer_NativeCDLLCuckooEngine_stop(JNIEnv* env, jobject obj)
{
    jintArray ret;
    jclass thisClass = env->GetObjectClass(obj);

    printf("cuckooengine stop --- \n");
    //// Get the Field ID of the instance variables "number"
    //jfieldID fidNumber = env->GetFieldID(thisClass, "mining_stop", "I");
    //jint number = env->GetIntField(obj, fidNumber);

    g_bStop = 1;

    return;
}
