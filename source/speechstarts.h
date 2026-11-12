// ibfix/speechstarts.h: made by tools/study/speechff.py (FIXES.md 78). Every spoken line (a wave with subtitles):
// its recording's length, where its words end, its pauses (from, to; seconds into the recording), and where it can
// pick up cleanly: the end of each pause, 20 ms before the next word ("clean"), then the quietest moments between
// words in running speech ("soft"). Measured from the recordings exported with UE Viewer (hd.noindex/speech-all).
typedef struct { const char *wave; float length, wordsEnd; int nPauses, nClean, nSoft; const float *pauses, *clean, *soft; } SpeechStarts;
static const float kPauses_faun_introspeech_01[] = { 0.00f, 0.10f, 3.75f, 4.72f };
static const float kClean_faun_introspeech_01[] = { 0.00f };
static const float kSoft_faun_introspeech_01[] = { 1.23f, 1.64f, 2.38f, 2.66f, 3.04f };
static const float kPauses_faun_introspeech_02[] = { 0.00f, 0.06f, 2.24f, 2.91f, 3.72f, 4.55f, 8.07f, 9.32f };
static const float kClean_faun_introspeech_02[] = { 0.00f, 2.89f, 4.53f };
static const float kSoft_faun_introspeech_02[] = { 0.63f, 1.03f, 1.58f, 1.80f, 1.98f, 5.62f, 6.12f, 6.31f, 7.71f };
static const float kPauses_faun_introspeech_03[] = { 0.00f, 0.04f, 0.79f, 0.89f, 0.90f, 1.45f, 3.81f, 4.56f, 5.60f, 6.17f, 6.29f, 6.35f, 9.07f, 9.14f, 9.46f, 10.64f };
static const float kClean_faun_introspeech_03[] = { 0.00f, 0.87f, 1.43f, 4.54f, 6.15f, 6.33f, 9.12f };
static const float kSoft_faun_introspeech_03[] = { 0.45f, 1.71f, 2.29f, 2.56f, 2.92f, 3.52f, 4.90f, 5.16f, 8.41f };
static const float kPauses_GK_Sc1Ln1[] = { 0.00f, 0.04f, 2.30f, 2.58f, 3.40f, 4.18f, 4.51f, 4.61f, 5.17f, 5.25f, 6.58f, 6.63f, 6.64f, 7.10f };
static const float kClean_GK_Sc1Ln1[] = { 0.00f, 2.56f, 4.16f, 4.59f, 5.23f, 6.61f };
static const float kSoft_GK_Sc1Ln1[] = { 1.40f, 1.69f, 2.10f, 5.80f };
static const float kPauses_GK_Sc1Ln1a[] = { 0.00f, 0.06f, 1.06f, 1.50f };
static const float kClean_GK_Sc1Ln1a[] = { 0.00f };
static const float kSoft_GK_Sc1Ln1a[] = { 0 };
static const float kPauses_GK_Sc1Ln3[] = { 0.00f, 0.15f, 1.88f, 1.96f, 2.19f, 2.24f, 3.27f, 3.38f, 5.20f, 5.62f };
static const float kClean_GK_Sc1Ln3[] = { 0.00f, 1.94f, 2.22f, 3.36f };
static const float kSoft_GK_Sc1Ln3[] = { 0.79f, 1.33f, 2.98f, 3.99f, 4.23f, 4.51f };
static const float kPauses_GK_Sc1Ln4[] = { 0.00f, 0.13f, 0.58f, 0.93f };
static const float kClean_GK_Sc1Ln4[] = { 0.00f };
static const float kSoft_GK_Sc1Ln4[] = { 0 };
static const float kPauses_GK_Sc1Ln5[] = { 0.00f, 0.10f, 0.62f, 1.15f, 1.54f, 1.62f, 1.90f, 2.05f, 4.00f, 4.73f, 5.64f, 5.78f, 6.50f, 6.55f, 7.12f, 7.90f, 10.44f, 10.87f };
static const float kClean_GK_Sc1Ln5[] = { 0.00f, 1.13f, 1.60f, 2.03f, 4.71f, 5.76f, 6.53f, 7.88f };
static const float kSoft_GK_Sc1Ln5[] = { 3.11f, 5.11f, 9.05f };
static const float kPauses_GK_Sc1Ln6[] = { 0.00f, 0.05f, 2.11f, 2.19f, 2.44f, 3.01f, 3.80f, 3.85f, 4.57f, 5.34f, 6.25f, 6.31f, 8.35f, 8.74f };
static const float kClean_GK_Sc1Ln6[] = { 0.00f, 2.17f, 2.99f, 3.83f, 5.32f, 6.29f };
static const float kSoft_GK_Sc1Ln6[] = { 1.01f, 1.54f, 3.60f, 6.94f };
static const float kPauses_GK_Sc1Ln7[] = { 0.00f, 0.17f, 1.97f, 2.21f, 3.73f, 4.01f, 4.04f, 4.33f, 6.79f, 6.84f, 8.77f, 9.15f };
static const float kClean_GK_Sc1Ln7[] = { 0.00f, 2.19f, 3.99f, 4.31f, 6.82f };
static const float kSoft_GK_Sc1Ln7[] = { 2.57f, 2.97f, 3.51f, 5.31f, 5.79f, 8.21f };
static const float kPauses_GK_Sc1Ln8[] = { 0.00f, 0.13f, 1.38f, 1.99f, 4.21f, 4.29f, 4.76f, 5.21f, 5.34f, 5.51f, 6.77f, 7.06f, 9.08f, 9.63f };
static const float kClean_GK_Sc1Ln8[] = { 0.00f, 1.97f, 4.27f, 5.19f, 5.49f, 7.04f };
static const float kSoft_GK_Sc1Ln8[] = { 0.90f, 2.65f, 3.16f, 3.44f, 6.05f, 7.29f, 7.72f, 8.26f };
static const float kPauses_GK_Sc2Ln1[] = { 0.00f, 0.07f, 2.40f, 2.84f, 3.81f, 3.95f, 4.21f, 4.30f, 4.80f, 4.97f, 5.24f, 5.40f, 5.67f, 5.82f, 6.65f, 6.70f, 7.24f, 7.36f, 8.64f, 8.98f };
static const float kClean_GK_Sc2Ln1[] = { 0.00f, 2.82f, 3.93f, 4.28f, 4.95f, 5.38f, 5.80f, 6.68f, 7.34f };
static const float kSoft_GK_Sc2Ln1[] = { 1.28f, 6.13f };
static const float kPauses_GK_Sc2Ln2[] = { 0.00f, 0.12f, 0.70f, 0.80f, 1.03f, 1.30f, 2.89f, 3.15f, 4.16f, 4.58f };
static const float kClean_GK_Sc2Ln2[] = { 0.00f, 0.78f, 1.28f, 3.13f };
static const float kSoft_GK_Sc2Ln2[] = { 2.13f };
static const float kPauses_GK_Sc3v1Ln1[] = { 0.00f, 0.13f, 2.55f, 2.92f };
static const float kClean_GK_Sc3v1Ln1[] = { 0.00f };
static const float kSoft_GK_Sc3v1Ln1[] = { 0.52f, 1.35f };
static const float kPauses_GK_Sc3v1Ln2[] = { 0.00f, 0.04f, 1.47f, 1.52f, 1.55f, 1.61f, 2.24f, 2.31f, 4.64f, 4.97f };
static const float kClean_GK_Sc3v1Ln2[] = { 0.00f, 1.50f, 1.59f, 2.29f };
static const float kSoft_GK_Sc3v1Ln2[] = { 3.30f, 3.76f, 4.25f };
static const float kPauses_GK_Sc3v1Ln3[] = { 0.00f, 0.14f, 3.06f, 3.40f };
static const float kClean_GK_Sc3v1Ln3[] = { 0.00f };
static const float kSoft_GK_Sc3v1Ln3[] = { 0.47f, 1.06f, 2.20f, 2.74f };
static const float kPauses_GK_Sc3v1Ln4[] = { 0.00f, 0.02f, 2.37f, 2.44f, 2.90f, 3.01f, 3.43f, 3.77f };
static const float kClean_GK_Sc3v1Ln4[] = { 0.00f, 2.42f, 2.99f };
static const float kSoft_GK_Sc3v1Ln4[] = { 1.32f, 1.65f, 2.16f };
static const float kPauses_GK_Sc4Ln1[] = { 0.00f, 0.15f, 0.79f, 0.84f, 0.97f, 1.39f, 2.12f, 2.23f, 2.78f, 2.83f, 4.40f, 4.47f, 4.86f, 5.55f, 6.74f, 6.92f, 8.51f, 8.82f, 10.88f, 10.93f, 11.93f, 12.02f, 13.06f, 13.42f };
static const float kClean_GK_Sc4Ln1[] = { 0.00f, 0.82f, 1.37f, 2.21f, 2.81f, 4.45f, 5.53f, 6.90f, 8.80f, 10.91f, 12.00f };
static const float kSoft_GK_Sc4Ln1[] = { 3.21f, 9.60f, 10.31f, 12.71f };
static const float kPauses_GK_Sc5Ln1[] = { 0.00f, 0.14f, 1.68f, 2.41f, 3.38f, 3.58f, 4.84f, 5.48f, 5.49f, 6.33f, 8.99f, 9.81f, 10.69f, 10.92f, 11.14f, 11.31f, 12.02f, 12.14f, 12.65f, 13.03f, 13.23f, 13.46f, 14.20f, 14.32f, 15.30f, 15.45f, 17.38f, 17.91f, 18.08f, 18.30f, 19.55f, 19.63f, 19.83f, 19.91f, 19.95f, 20.01f, 21.27f, 21.33f, 21.57f, 21.65f, 22.53f, 22.59f, 23.44f, 23.60f, 23.75f, 23.95f, 24.86f, 24.94f, 25.19f, 25.31f, 27.58f, 28.08f };
static const float kClean_GK_Sc5Ln1[] = { 0.00f, 2.39f, 3.56f, 5.46f, 6.31f, 9.79f, 10.90f, 11.29f, 12.12f, 13.01f, 13.44f, 14.30f, 15.43f, 17.89f, 18.28f, 19.61f, 19.89f, 19.99f, 21.31f, 21.63f, 22.57f, 23.58f, 23.93f, 24.92f, 25.29f };
static const float kSoft_GK_Sc5Ln1[] = { 4.06f, 7.04f, 7.67f, 8.14f, 8.69f, 16.25f, 16.93f, 18.81f, 19.08f, 20.52f, 26.41f };
static const float kPauses_GK_Sc6Ln2[] = { 0.00f, 0.10f, 0.32f, 0.51f, 1.42f, 1.62f, 1.70f, 1.79f, 1.91f, 2.00f, 3.03f, 3.11f, 3.89f, 4.27f, 6.90f, 7.28f };
static const float kClean_GK_Sc6Ln2[] = { 0.00f, 0.49f, 1.60f, 1.77f, 1.98f, 3.09f, 4.25f };
static const float kSoft_GK_Sc6Ln2[] = { 3.61f, 5.58f };
static const float kPauses_GK_Sc7Ln1[] = { 0.00f, 0.20f, 0.79f, 0.93f, 0.95f, 1.13f, 1.95f, 2.40f, 2.65f, 2.77f, 2.78f, 3.38f, 3.99f, 4.86f, 5.93f, 6.05f, 6.09f, 6.76f, 6.91f, 7.24f, 7.59f, 7.77f, 7.85f, 8.09f };
static const float kClean_GK_Sc7Ln1[] = { 0.00f, 0.91f, 1.11f, 2.38f, 2.75f, 3.36f, 4.84f, 6.03f, 6.74f, 7.22f, 7.75f };
static const float kSoft_GK_Sc7Ln1[] = { 1.72f };
static const float kPauses_GK_Sc7Ln2[] = { 0.00f, 0.16f, 0.85f, 0.91f, 0.95f, 1.19f, 1.46f, 1.78f, 1.80f, 2.34f, 2.96f, 3.54f, 5.19f, 5.26f, 5.60f, 5.70f, 5.80f, 5.98f, 5.99f, 6.05f, 6.27f, 6.49f, 7.61f, 8.41f, 8.80f, 8.85f, 9.90f, 9.99f, 10.47f, 10.54f, 10.56f, 10.61f, 11.41f, 11.50f, 12.02f, 12.11f, 13.10f, 13.75f, 13.86f, 13.99f, 14.56f, 14.68f, 14.71f, 15.01f, 15.69f, 15.88f, 15.96f, 16.22f, 16.26f, 16.35f, 16.42f, 16.47f, 16.60f, 16.68f, 17.27f, 17.61f };
static const float kClean_GK_Sc7Ln2[] = { 0.00f, 0.89f, 1.17f, 1.76f, 2.32f, 3.52f, 5.24f, 5.68f, 5.96f, 6.03f, 6.47f, 8.39f, 8.83f, 9.97f, 10.52f, 10.59f, 11.48f, 12.09f, 13.73f, 13.97f, 14.66f, 14.99f, 15.86f, 16.20f, 16.33f, 16.45f, 16.66f };
static const float kSoft_GK_Sc7Ln2[] = { 4.27f, 6.82f, 10.80f, 11.04f, 15.53f };
static const float kPauses_KN_Sc1Ln2[] = { 0.00f, 0.20f, 0.48f, 0.53f, 1.32f, 1.38f, 1.61f, 2.35f, 4.47f, 4.53f, 5.30f, 5.61f };
static const float kClean_KN_Sc1Ln2[] = { 0.00f, 0.51f, 1.36f, 2.33f, 4.51f };
static const float kSoft_KN_Sc1Ln2[] = { 2.98f, 3.58f, 3.75f, 4.74f, 5.01f };
static const float kPauses_KN_Sc2aLn1_01[] = { 0.00f, 0.01f, 0.69f, 1.13f, 2.05f, 2.22f };
static const float kClean_KN_Sc2aLn1_01[] = { 0.00f, 1.11f };
static const float kSoft_KN_Sc2aLn1_01[] = { 0.23f, 1.32f };
static const float kPauses_knight_talktofaun_01[] = { 0.00f, 0.02f, 0.72f, 1.30f, 2.35f, 2.40f, 2.83f, 3.20f };
static const float kClean_knight_talktofaun_01[] = { 0.00f, 1.28f, 2.38f };
static const float kSoft_knight_talktofaun_01[] = { 2.16f };
static const float kPauses_knight_talktozero_01[] = { 0.00f, 0.01f, 0.39f, 0.88f, 1.92f, 2.58f };
static const float kClean_knight_talktozero_01[] = { 0.00f, 0.86f };
static const float kSoft_knight_talktozero_01[] = { 1.12f, 1.62f };
static const float kPauses_knight_talktozero_02[] = { 0.00f, 0.04f, 1.05f, 1.67f };
static const float kClean_knight_talktozero_02[] = { 0.00f };
static const float kSoft_knight_talktozero_02[] = { 0.68f };
static const float kPauses_knight_talktozero_03[] = { 0.00f, 0.01f, 1.03f, 1.08f, 2.18f, 2.80f, 3.27f, 3.44f, 3.85f, 3.90f, 4.07f, 4.12f, 4.67f, 5.06f };
static const float kClean_knight_talktozero_03[] = { 0.00f, 1.06f, 2.78f, 3.42f, 3.88f, 4.10f };
static const float kSoft_knight_talktozero_03[] = { 0.16f, 0.64f, 1.40f, 1.81f, 4.43f };
static const float kPauses_knight_talktozero_04[] = { 0.00f, 0.05f, 1.27f, 1.79f, 2.64f, 3.24f, 4.17f, 4.71f, 5.55f, 6.47f, 6.65f, 6.81f, 7.78f, 8.56f };
static const float kClean_knight_talktozero_04[] = { 0.00f, 1.77f, 3.22f, 4.69f, 6.45f, 6.79f };
static const float kSoft_knight_talktozero_04[] = { 0.62f, 2.02f, 2.23f, 2.44f, 3.49f, 3.65f, 4.91f, 7.04f };
static const float kPauses_knight_talktozero_05[] = { 0.00f, 0.01f, 1.14f, 1.73f, 2.27f, 2.39f, 3.08f, 4.00f };
static const float kClean_knight_talktozero_05[] = { 0.00f, 1.71f, 2.37f };
static const float kSoft_knight_talktozero_05[] = { 0 };
static const float kPauses_mech_introspeech_01[] = { 3.51f, 3.68f, 10.60f, 11.48f };
static const float kClean_mech_introspeech_01[] = { 0.00f, 3.66f };
static const float kSoft_mech_introspeech_01[] = { 2.53f, 3.13f, 4.74f, 5.49f, 6.27f, 6.50f, 6.71f, 8.25f, 8.76f, 9.66f, 10.08f };
static const float kPauses_ninja_introspeech_01[] = { 0.00f, 0.54f, 2.19f, 2.70f, 5.18f, 5.23f, 5.25f, 6.35f };
static const float kClean_ninja_introspeech_01[] = { 0.00f, 2.68f, 5.21f };
static const float kSoft_ninja_introspeech_01[] = { 1.34f, 3.45f, 3.76f, 3.94f, 4.41f, 4.58f };
static const float kPauses_zero_deathspeech[] = { 0.00f, 0.02f, 0.43f, 0.67f, 0.95f, 1.13f, 2.66f, 2.88f, 2.89f, 3.03f, 4.66f, 5.50f, 6.34f, 6.48f, 6.93f, 7.06f, 8.57f, 9.40f, 10.28f, 11.06f, 12.49f, 13.31f, 13.56f, 13.62f, 13.77f, 14.18f, 14.93f, 14.98f, 15.59f, 16.42f };
static const float kClean_zero_deathspeech[] = { 0.00f, 0.65f, 1.11f, 2.86f, 3.01f, 5.48f, 6.46f, 7.04f, 9.38f, 11.04f, 13.29f, 13.60f, 14.16f, 14.96f };
static const float kSoft_zero_deathspeech[] = { 0.24f, 2.35f, 3.51f, 4.25f, 6.12f, 7.26f, 7.58f, 9.99f, 11.81f, 11.98f, 15.23f };
static const float kPauses_zero_introspeech_01[] = { 0.00f, 0.01f, 0.38f, 0.58f, 0.66f, 1.17f, 3.21f, 3.86f, 5.80f, 6.62f };
static const float kClean_zero_introspeech_01[] = { 0.00f, 0.56f, 1.15f, 3.84f };
static const float kSoft_zero_introspeech_01[] = { 1.68f, 2.18f, 2.48f, 4.29f, 4.80f, 5.07f };
static const float kPauses_zero_introspeech_02[] = { 0.00f, 0.07f, 2.48f, 3.60f, 5.26f, 5.58f, 7.60f, 7.79f, 8.02f, 8.07f, 8.39f, 8.46f, 8.71f, 9.93f };
static const float kClean_zero_introspeech_02[] = { 0.00f, 3.58f, 5.56f, 7.77f, 8.05f, 8.44f };
static const float kSoft_zero_introspeech_02[] = { 0.85f, 1.41f, 1.79f, 3.75f, 3.94f, 4.34f, 4.67f, 4.93f, 5.92f, 6.68f, 7.12f };
static const float kPauses_zero_introspeech_03[] = { 0.00f, 0.04f, 1.00f, 1.17f, 1.94f, 2.70f, 4.14f, 4.99f, 6.43f, 6.50f, 8.15f, 8.71f, 10.46f, 10.82f, 11.94f, 12.57f };
static const float kClean_zero_introspeech_03[] = { 0.00f, 1.15f, 2.68f, 4.97f, 6.48f, 8.69f, 10.80f };
static const float kSoft_zero_introspeech_03[] = { 3.21f, 3.57f, 3.85f, 6.01f, 6.89f, 7.48f, 7.80f, 8.91f, 9.54f, 10.02f, 11.22f };
static const float kPauses_zero_introspeech_04[] = { 0.00f, 0.01f, 0.43f, 1.05f, 2.34f, 3.07f, 5.99f, 7.00f };
static const float kClean_zero_introspeech_04[] = { 0.00f, 1.03f, 3.05f };
static const float kSoft_zero_introspeech_04[] = { 1.82f, 3.40f, 4.54f };
static const SpeechStarts kSpeechStarts[] = {
    { "faun_introspeech_01", 4.72f, 3.76f, 2, 1, 5, kPauses_faun_introspeech_01, kClean_faun_introspeech_01, kSoft_faun_introspeech_01 },
    { "faun_introspeech_02", 9.32f, 8.08f, 4, 3, 9, kPauses_faun_introspeech_02, kClean_faun_introspeech_02, kSoft_faun_introspeech_02 },
    { "faun_introspeech_03", 10.63f, 9.47f, 8, 7, 9, kPauses_faun_introspeech_03, kClean_faun_introspeech_03, kSoft_faun_introspeech_03 },
    { "GK_Sc1Ln1", 7.12f, 6.65f, 7, 6, 4, kPauses_GK_Sc1Ln1, kClean_GK_Sc1Ln1, kSoft_GK_Sc1Ln1 },
    { "GK_Sc1Ln1a", 1.51f, 1.07f, 2, 1, 0, kPauses_GK_Sc1Ln1a, kClean_GK_Sc1Ln1a, kSoft_GK_Sc1Ln1a },
    { "GK_Sc1Ln3", 5.63f, 5.21f, 5, 4, 6, kPauses_GK_Sc1Ln3, kClean_GK_Sc1Ln3, kSoft_GK_Sc1Ln3 },
    { "GK_Sc1Ln4", 0.94f, 0.59f, 2, 1, 0, kPauses_GK_Sc1Ln4, kClean_GK_Sc1Ln4, kSoft_GK_Sc1Ln4 },
    { "GK_Sc1Ln5", 10.89f, 10.45f, 9, 8, 3, kPauses_GK_Sc1Ln5, kClean_GK_Sc1Ln5, kSoft_GK_Sc1Ln5 },
    { "GK_Sc1Ln6", 8.75f, 8.36f, 7, 6, 4, kPauses_GK_Sc1Ln6, kClean_GK_Sc1Ln6, kSoft_GK_Sc1Ln6 },
    { "GK_Sc1Ln7", 9.17f, 8.78f, 6, 5, 6, kPauses_GK_Sc1Ln7, kClean_GK_Sc1Ln7, kSoft_GK_Sc1Ln7 },
    { "GK_Sc1Ln8", 9.65f, 9.09f, 7, 6, 8, kPauses_GK_Sc1Ln8, kClean_GK_Sc1Ln8, kSoft_GK_Sc1Ln8 },
    { "GK_Sc2Ln1", 8.99f, 8.65f, 10, 9, 2, kPauses_GK_Sc2Ln1, kClean_GK_Sc2Ln1, kSoft_GK_Sc2Ln1 },
    { "GK_Sc2Ln2", 4.60f, 4.17f, 5, 4, 1, kPauses_GK_Sc2Ln2, kClean_GK_Sc2Ln2, kSoft_GK_Sc2Ln2 },
    { "GK_Sc3v1Ln1", 2.93f, 2.56f, 2, 1, 2, kPauses_GK_Sc3v1Ln1, kClean_GK_Sc3v1Ln1, kSoft_GK_Sc3v1Ln1 },
    { "GK_Sc3v1Ln2", 4.99f, 4.65f, 5, 4, 3, kPauses_GK_Sc3v1Ln2, kClean_GK_Sc3v1Ln2, kSoft_GK_Sc3v1Ln2 },
    { "GK_Sc3v1Ln3", 3.41f, 3.07f, 2, 1, 4, kPauses_GK_Sc3v1Ln3, kClean_GK_Sc3v1Ln3, kSoft_GK_Sc3v1Ln3 },
    { "GK_Sc3v1Ln4", 3.78f, 3.44f, 4, 3, 3, kPauses_GK_Sc3v1Ln4, kClean_GK_Sc3v1Ln4, kSoft_GK_Sc3v1Ln4 },
    { "GK_Sc4Ln1", 13.44f, 13.07f, 12, 11, 4, kPauses_GK_Sc4Ln1, kClean_GK_Sc4Ln1, kSoft_GK_Sc4Ln1 },
    { "GK_Sc5Ln1", 28.09f, 27.59f, 26, 25, 11, kPauses_GK_Sc5Ln1, kClean_GK_Sc5Ln1, kSoft_GK_Sc5Ln1 },
    { "GK_Sc6Ln2", 7.29f, 6.91f, 8, 7, 2, kPauses_GK_Sc6Ln2, kClean_GK_Sc6Ln2, kSoft_GK_Sc6Ln2 },
    { "GK_Sc7Ln1", 8.11f, 7.86f, 12, 11, 1, kPauses_GK_Sc7Ln1, kClean_GK_Sc7Ln1, kSoft_GK_Sc7Ln1 },
    { "GK_Sc7Ln2", 17.63f, 17.28f, 28, 27, 5, kPauses_GK_Sc7Ln2, kClean_GK_Sc7Ln2, kSoft_GK_Sc7Ln2 },
    { "KN_Sc1Ln2", 5.62f, 5.31f, 6, 5, 5, kPauses_KN_Sc1Ln2, kClean_KN_Sc1Ln2, kSoft_KN_Sc1Ln2 },
    { "KN_Sc2aLn1-01", 2.23f, 2.06f, 3, 2, 2, kPauses_KN_Sc2aLn1_01, kClean_KN_Sc2aLn1_01, kSoft_KN_Sc2aLn1_01 },
    { "knight_talktofaun_01", 3.21f, 2.84f, 4, 3, 1, kPauses_knight_talktofaun_01, kClean_knight_talktofaun_01, kSoft_knight_talktofaun_01 },
    { "knight_talktozero_01", 2.58f, 1.93f, 3, 2, 2, kPauses_knight_talktozero_01, kClean_knight_talktozero_01, kSoft_knight_talktozero_01 },
    { "knight_talktozero_02", 1.68f, 1.06f, 2, 1, 1, kPauses_knight_talktozero_02, kClean_knight_talktozero_02, kSoft_knight_talktozero_02 },
    { "knight_talktozero_03", 5.06f, 4.68f, 7, 6, 5, kPauses_knight_talktozero_03, kClean_knight_talktozero_03, kSoft_knight_talktozero_03 },
    { "knight_talktozero_04", 8.56f, 7.79f, 7, 6, 8, kPauses_knight_talktozero_04, kClean_knight_talktozero_04, kSoft_knight_talktozero_04 },
    { "knight_talktozero_05", 4.01f, 3.09f, 4, 3, 0, kPauses_knight_talktozero_05, kClean_knight_talktozero_05, kSoft_knight_talktozero_05 },
    { "mech_introspeech_01", 11.47f, 10.61f, 2, 2, 11, kPauses_mech_introspeech_01, kClean_mech_introspeech_01, kSoft_mech_introspeech_01 },
    { "ninja_introspeech_01", 6.35f, 5.26f, 4, 3, 6, kPauses_ninja_introspeech_01, kClean_ninja_introspeech_01, kSoft_ninja_introspeech_01 },
    { "zero_deathspeech", 16.40f, 15.60f, 15, 14, 11, kPauses_zero_deathspeech, kClean_zero_deathspeech, kSoft_zero_deathspeech },
    { "zero_introspeech_01", 6.62f, 5.81f, 5, 4, 6, kPauses_zero_introspeech_01, kClean_zero_introspeech_01, kSoft_zero_introspeech_01 },
    { "zero_introspeech_02", 9.92f, 8.72f, 7, 6, 11, kPauses_zero_introspeech_02, kClean_zero_introspeech_02, kSoft_zero_introspeech_02 },
    { "zero_introspeech_03", 12.56f, 11.95f, 8, 7, 11, kPauses_zero_introspeech_03, kClean_zero_introspeech_03, kSoft_zero_introspeech_03 },
    { "zero_introspeech_04", 7.00f, 6.00f, 4, 3, 3, kPauses_zero_introspeech_04, kClean_zero_introspeech_04, kSoft_zero_introspeech_04 },
};
enum { kNumSpeechStarts = 37 };
