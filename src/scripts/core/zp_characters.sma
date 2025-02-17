#pragma semicolon 1

#include <amxmodx>
#include <amxmisc>
#include <hamsandwich>
#include <fakemeta>
#include <reapi>
#include <json>

#include <zombiepanic>
#include <api_custom_weapons>

#define PLUGIN "[Zombie Panic] Characters"
#define AUTHOR "Hedgehog Fog"

#define TASKID_AMBIENT 100

#define DOCUMENT_VERSION 2
#define RESERVED_CHARACTER_COUNT 4
#define RESERVED_SOUND_COUNT 3
#define CHARACTER_KEY "zp_character"
#define DEFAULT_PLAYER_MODEL "models/player/vip/vip.mdl"

enum CharacterData {
    Character_HumanModel,
    Character_ZombieModel,
    Character_SwipeModel,
    Character_HumanDeathSounds,
    Character_PanicSounds,
    Character_ZombieAmbientSounds,
    Character_ZombieDeathSounds,
    Character_IsSelectable,
    Character_BodyIndex
}

new gmsgClCorpse;

new g_szCharacterDir[MAX_RESOURCE_PATH_LENGTH];

new Array:g_rgCharactersData[CharacterData];
new Trie:g_iCharactersMap;
new Array:g_iSelectableCharacters;
new g_iCharacterCount = 0;

new g_iPlayerCharacter[MAX_PLAYERS + 1] = { -1, ... };

new CW:g_iCwSwipeHandler;

new g_pFwPlayerCharacterUpdated;
new g_pFwPlayerModelUpdated;
new g_iFwResult;

public plugin_precache() {
    precache_model(DEFAULT_PLAYER_MODEL);

    get_configsdir(g_szCharacterDir, charsmax(g_szCharacterDir));
    format(g_szCharacterDir, charsmax(g_szCharacterDir), "%s/zombiepanic/characters", g_szCharacterDir);

    InitializeCharactersStore();
    LoadCharacters();
}

public plugin_init() {
    register_plugin(PLUGIN, ZP_VERSION, AUTHOR);

    gmsgClCorpse = get_user_msgid("ClCorpse");

    RegisterHam(Ham_Spawn, "player", "OnPlayerSpawn_Post", .Post = 1);
    RegisterHam(Ham_Killed, "player", "OnPlayerKilled_Post", .Post = 1);
    RegisterHam(Ham_PainSound, "player", "OnPlayerPainSound_Post", .Post = 1);
    RegisterHam(Ham_Item_Deploy, "weapon_knife", "OnKnifeDeploy_Post", .Post = 1);

    register_forward(FM_SetClientKeyValue, "OnSetClientKeyValue");

    register_message(gmsgClCorpse, "OnMessage_ClCorpse");

    g_iCwSwipeHandler = CW_GetHandler(ZP_WEAPON_SWIPE);

    g_pFwPlayerCharacterUpdated = CreateMultiForward("ZP_Fw_PlayerCharacterUpdated", ET_IGNORE, FP_CELL);
    g_pFwPlayerModelUpdated = CreateMultiForward("ZP_Fw_PlayerModelUpdated", ET_IGNORE, FP_CELL);
}

public plugin_natives() {
    register_native("ZP_Player_SetCharacter", "Native_SetCharacter");
}

public plugin_end() {
    DestroyCharactersStore();
}

/*--------------------------------[ Natives ]--------------------------------*/

public bool:Native_SetCharacter(iPluginId, iArgc) {
    new pPlayer = get_param(1);

    new szCharacter[32];
    get_string(2, szCharacter, charsmax(szCharacter));

    return SetCharacter(pPlayer, szCharacter);
}

/*--------------------------------[ Forwards ]--------------------------------*/

public client_connect(pPlayer) {
    UpdatePlayerCharacter(pPlayer, true);
}

public client_putinserver(pPlayer) {
    if (!is_user_bot(pPlayer)) {
        set_task(5.0, "Task_DisableMinModels", pPlayer);
    }
}

public ZP_Fw_PlayerPanic(pPlayer) {
    PlayVoiceFromCharacterData(pPlayer, Character_PanicSounds);
}

public ZP_Fw_PlayerZombieVision(pPlayer) {
    PlayAmbient(pPlayer);
}

/*--------------------------------[ Hooks ]--------------------------------*/

public OnPlayerSpawn_Post(pPlayer) {
    UpdatePlayerCharacter(pPlayer);
    UpdatePlayerModel(pPlayer);

    remove_task(TASKID_AMBIENT + pPlayer);
    set_task(0.1, "Task_Ambient", TASKID_AMBIENT + pPlayer);

    return HAM_HANDLED;
}

public OnPlayerKilled_Post(pPlayer) {
    PlayVoiceFromCharacterData(pPlayer, ZP_Player_IsZombie(pPlayer) && !ZP_Player_IsInfected(pPlayer) ? Character_ZombieDeathSounds : Character_HumanDeathSounds);
    return HAM_HANDLED;
}

public OnPlayerPainSound_Post(pPlayer) {
    emit_sound(pPlayer, CHAN_VOICE, "common/null.wav", VOL_NORM, ATTN_NORM, 0, PITCH_NORM);
}

public OnKnifeDeploy_Post(pKnife) {
    if (CW_GetHandlerByEntity(pKnife) == g_iCwSwipeHandler) {
        new pPlayer = CW_GetPlayer(pKnife);
        if (g_iPlayerCharacter[pPlayer] == -1) {
            return HAM_IGNORED;
        }

        static szModel[64];
        ArrayGetString(Array:g_rgCharactersData[Character_SwipeModel], g_iPlayerCharacter[pPlayer], szModel, charsmax(szModel));
        set_pev(pPlayer, pev_viewmodel2, szModel);
    }

    return HAM_HANDLED;
}

public OnSetClientKeyValue(pPlayer, const szInfoBuffer[], const szKey[], const szValue[]) {
    if (equal(szKey, "model")) {
        UpdatePlayerModel(pPlayer);
        return FMRES_SUPERCEDE;
    }

    return FMRES_IGNORED;
}

public OnMessage_ClCorpse(iMsgId, iMsgDest, pPlayer) {
    new pTargetPlayer = get_msg_arg_int(12);
    new iCharacter = g_iPlayerCharacter[pTargetPlayer];

    static szPlayerModel[MAX_RESOURCE_PATH_LENGTH];
    ArrayGetString(Array:g_rgCharactersData[ZP_Player_IsZombie(pTargetPlayer) ? Character_ZombieModel : Character_HumanModel], iCharacter, szPlayerModel, charsmax(szPlayerModel));

    if (szPlayerModel[0] == '^0') {
        return;
    }

    set_msg_arg_string(1, szPlayerModel);
}

/*--------------------------------[ Tasks ]--------------------------------*/

public Task_Ambient(iTaskId) {
    new pPlayer = iTaskId - TASKID_AMBIENT;

    PlayAmbient(pPlayer);
    set_task(random_float(10.0, 30.0), "Task_Ambient", TASKID_AMBIENT + pPlayer);
}

public Task_DisableMinModels(iTaskId) {
    new pPlayer = iTaskId;

    if (!is_user_connected(pPlayer)) {
        return;
    }

    client_cmd(pPlayer, "cl_minmodels %d", 0);
}

/*--------------------------------[ Methods ]--------------------------------*/

bool:SetCharacter(pPlayer, const szCharacter[]) {
    new iCharacter;
    if (!TrieGetCell(g_iCharactersMap, szCharacter, iCharacter)) {
        return false;
    }

    g_iPlayerCharacter[pPlayer] = iCharacter;

    return true;
}

UpdatePlayerModel(pPlayer) {
    new iCharacter = g_iPlayerCharacter[pPlayer];

    static szPlayerModel[MAX_RESOURCE_PATH_LENGTH];
    copy(szPlayerModel, 0, "");

    if (g_iPlayerCharacter[pPlayer] != -1) {
        ArrayGetString(Array:g_rgCharactersData[ZP_Player_IsZombie(pPlayer) ? Character_ZombieModel : Character_HumanModel], iCharacter, szPlayerModel, charsmax(szPlayerModel));
    }

    if (szPlayerModel[0] == '^0') {
        copy(szPlayerModel, charsmax(szPlayerModel), DEFAULT_PLAYER_MODEL);
    }

    new iModelIndex = engfunc(EngFunc_ModelIndex, szPlayerModel);
    new iBody = ArrayGetCell(Array:g_rgCharactersData[Character_BodyIndex], iCharacter);

    set_user_info(pPlayer, "model", NULL_STRING);
    set_pev(pPlayer, pev_modelindex, iModelIndex);
    set_pev(pPlayer, pev_body, iBody);
    set_member(pPlayer, m_modelIndexPlayer, iModelIndex);

    ExecuteForward(g_pFwPlayerModelUpdated, g_iFwResult, pPlayer);
}

UpdatePlayerCharacter(pPlayer, bool:bOverride = false) {
    if (!g_iCharacterCount) {
        return;
    }

    static szCharacter[16];
    get_user_info(pPlayer, CHARACTER_KEY, szCharacter, charsmax(szCharacter));

    new iCharacter;
    if (!TrieGetCell(g_iCharactersMap, szCharacter, iCharacter)
        || !ArrayGetCell(Array:g_rgCharactersData[Character_IsSelectable], iCharacter)) {
        if (!bOverride) {
            return;
        }

        iCharacter = ArrayGetCell(g_iSelectableCharacters, random(ArraySize(g_iSelectableCharacters)));
    }

    g_iPlayerCharacter[pPlayer] = iCharacter;
    ExecuteForward(g_pFwPlayerCharacterUpdated, g_iFwResult, pPlayer);
}

PlayAmbient(pPlayer) {
    if (!is_user_alive(pPlayer)) {
        return;
    }

    if (ZP_Player_IsZombie(pPlayer)) {
        PlayVoiceFromCharacterData(pPlayer, Character_ZombieAmbientSounds);
    }
}

PlayVoiceFromCharacterData(pPlayer, CharacterData:iCharacterData) {
    if (g_iPlayerCharacter[pPlayer] == -1) {
        return;
    }

    new Array:irgSounds = ArrayGetCell(Array:g_rgCharactersData[iCharacterData], g_iPlayerCharacter[pPlayer]);
    if (!ArraySize(irgSounds)) {
        return;
    }

    static szSound[MAX_RESOURCE_PATH_LENGTH];
    ArrayGetString(irgSounds, random(ArraySize(irgSounds)), szSound, charsmax(szSound));
    emit_sound(pPlayer, CHAN_VOICE, szSound, VOL_NORM, ATTN_NORM, 0, PITCH_NORM);
}

CreateCharacter(iBaseCharacter = -1) {
    new iCharacter = g_iCharacterCount;

    for (new i = 0; i < sizeof(g_rgCharactersData); ++i)    {
        ArrayPushCell(g_rgCharactersData[CharacterData:i], 0);
    }

    CrateCharacterSoundsData(iCharacter, Character_HumanDeathSounds);
    CrateCharacterSoundsData(iCharacter, Character_PanicSounds);
    CrateCharacterSoundsData(iCharacter, Character_ZombieAmbientSounds);
    CrateCharacterSoundsData(iCharacter, Character_ZombieDeathSounds);

    ArraySetCell(Array:g_rgCharactersData[Character_IsSelectable], iCharacter, true);
    ArraySetCell(Array:g_rgCharactersData[Character_BodyIndex], iCharacter, 0);

    if (iBaseCharacter != -1) {
        InterhitCharacter(iCharacter, iBaseCharacter);
    }

    g_iCharacterCount++;

    return iCharacter;
}

DestroyCharacter(iCharacter) {
    DestroyCharacterSoundData(iCharacter, Character_HumanDeathSounds);
    DestroyCharacterSoundData(iCharacter, Character_PanicSounds);
    DestroyCharacterSoundData(iCharacter, Character_ZombieAmbientSounds);
    DestroyCharacterSoundData(iCharacter, Character_ZombieDeathSounds);
}

InterhitCharacter(iCharacter, iBaseCharacter) {
    InterhitCharacterModel(iCharacter, iBaseCharacter, Character_HumanModel);
    InterhitCharacterModel(iCharacter, iBaseCharacter, Character_ZombieModel);
    InterhitCharacterModel(iCharacter, iBaseCharacter, Character_SwipeModel);
    InheritCharacterSounds(iCharacter, iBaseCharacter, Character_HumanDeathSounds);
    InheritCharacterSounds(iCharacter, iBaseCharacter, Character_PanicSounds);
    InheritCharacterSounds(iCharacter, iBaseCharacter, Character_ZombieAmbientSounds);
    InheritCharacterSounds(iCharacter, iBaseCharacter, Character_ZombieDeathSounds);
    InterhitCharacterValue(iCharacter, iBaseCharacter, Character_BodyIndex);
    InterhitCharacterValue(iCharacter, iBaseCharacter, Character_IsSelectable);
}

InterhitCharacterValue(iCharacter, iBaseCharacter, CharacterData:iCharacterData) {
    new iBaseValue = ArrayGetCell(Array:g_rgCharactersData[iCharacterData], iBaseCharacter);
    ArraySetCell(Array:g_rgCharactersData[iCharacterData], iCharacter, iBaseValue);
}

InterhitCharacterModel(iCharacter, iBaseCharacter, CharacterData:iCharacterData) {
    new szBuffer[MAX_RESOURCE_PATH_LENGTH];

    ArrayGetString(Array:g_rgCharactersData[iCharacterData], iBaseCharacter, szBuffer, charsmax(szBuffer));
    ArraySetString(Array:g_rgCharactersData[iCharacterData], iCharacter, szBuffer);
}

InheritCharacterSounds(iCharacter, iBaseCharacter, CharacterData:iCharacterData) {
    new szBuffer[MAX_RESOURCE_PATH_LENGTH];

    new Array:irgSounds = ArrayGetCell(Array:g_rgCharactersData[iCharacterData], iCharacter);
    new Array:irgBaseSounds = ArrayGetCell(Array:g_rgCharactersData[iCharacterData], iBaseCharacter);
    new iSize = ArraySize(irgBaseSounds);

    for (new i = 0; i < iSize; ++i) {
        ArrayGetString(irgBaseSounds, i, szBuffer, charsmax(szBuffer));
        ArrayPushString(irgSounds, szBuffer);
    }
}

CrateCharacterSoundsData(iCharacter, CharacterData:iCharacterData) {
    new Array:irgSounds = ArrayCreate(MAX_RESOURCE_PATH_LENGTH, RESERVED_SOUND_COUNT);
    ArraySetCell(Array:g_rgCharactersData[iCharacterData], iCharacter, irgSounds);
}

DestroyCharacterSoundData(iCharacter, CharacterData:iCharacterData) {
    new Array:irgSounds = ArrayGetCell(Array:g_rgCharactersData[iCharacterData], iCharacter);
    ArrayDestroy(irgSounds);
}

LoadCharacters() {
    new szFileName[32];

    new FileType:iFileType;
    new iDir = open_dir(g_szCharacterDir, szFileName, charsmax(szFileName), iFileType);

    if (!iDir) {
        return;
    }

    do {
        if (iFileType != FileType_File) {
            continue;
        }

        new iLen = strlen(szFileName);
        if (iLen > 5 && equal(szFileName[iLen - 5], ".json")) {
            new szName[16];
            copy(szName, iLen - 5, szFileName);
            if (!TrieKeyExists(g_iCharactersMap, szName)) {
                LoadCharacter(szName);
            }
        }

    } while (next_file(iDir, szFileName, charsmax(szFileName), iFileType));

    close_dir(iDir);
}

LoadCharacter(const szName[]) {
    new szFilePath[MAX_RESOURCE_PATH_LENGTH];
    format(szFilePath, charsmax(szFilePath), "%s/%s.json", g_szCharacterDir, szName);

    new JSON:iDoc = json_parse(szFilePath, true);
    new iVersion = json_object_get_number(iDoc, "_version");
    if (iVersion > DOCUMENT_VERSION) {
        log_amx("Cannot load character %s. Character version should be less than or equal to %d.", szName, DOCUMENT_VERSION);
        return -1;
    }

    new iBaseCharacter = -1;
    if (json_object_has_value(iDoc, "inherit")) {
        new szBase[16];
        json_object_get_string(iDoc, "inherit", szBase, charsmax(szBase));

        if (!TrieGetCell(g_iCharactersMap, szBase, iBaseCharacter)) {
            iBaseCharacter = LoadCharacter(szBase);
        }
    }

    new iCharacter = CreateCharacter(iBaseCharacter);
    TrieSetCell(g_iCharactersMap, szName, iCharacter);

    new JSON:iModelsDoc = json_object_get_value(iDoc, "models");
    if (iModelsDoc != Invalid_JSON) {
        LoadCharacterModelData(iCharacter, iModelsDoc, "human", Character_HumanModel);
        LoadCharacterModelData(iCharacter, iModelsDoc, "zombie", Character_ZombieModel);
        LoadCharacterModelData(iCharacter, iModelsDoc, "swipe", Character_SwipeModel);
    }

    new JSON:iSoundsDoc = json_object_get_value(iDoc, "sounds");
    if (iSoundsDoc != Invalid_JSON) {
        LoadCharacterSoundsData(iCharacter, iSoundsDoc, "human.death", Character_HumanDeathSounds);
        LoadCharacterSoundsData(iCharacter, iSoundsDoc, "human.panic", Character_PanicSounds);
        LoadCharacterSoundsData(iCharacter, iSoundsDoc, "zombie.ambient", Character_ZombieAmbientSounds);
        LoadCharacterSoundsData(iCharacter, iSoundsDoc, "zombie.death", Character_ZombieDeathSounds);
    }

    if (json_object_has_value(iDoc, "selectable")) {
        ArraySetCell(Array:g_rgCharactersData[Character_IsSelectable], iCharacter, json_object_get_bool(iDoc, "selectable"));
    }

    if (json_object_has_value(iDoc, "bodyindex")) {
        ArraySetCell(Array:g_rgCharactersData[Character_BodyIndex], iCharacter, json_object_get_number(iDoc, "bodyindex"));
    }

    if (ArrayGetCell(Array:g_rgCharactersData[Character_IsSelectable], iCharacter)) {
        ArrayPushCell(g_iSelectableCharacters, iCharacter);
    }

    log_amx("Character %s loaded.", szName);

    return iCharacter;
}

LoadCharacterModelData(iCharacter, JSON:iModelsDoc, const szKey[], CharacterData:iCharacterData) {
    if (!json_object_has_value(iModelsDoc, szKey)) {
        return;
    }

    new szBuffer[MAX_RESOURCE_PATH_LENGTH];

    json_object_get_string(iModelsDoc, szKey, szBuffer, charsmax(szBuffer));
    ArraySetString(Array:g_rgCharactersData[iCharacterData], iCharacter, szBuffer);
    precache_model(szBuffer);
}

LoadCharacterSoundsData(iCharacter, JSON:iSoundDoc, const szKey[], CharacterData:iCharacterData) {
    if (!json_object_has_value(iSoundDoc, szKey, _, true)) {
        return;
    }

    new szBuffer[MAX_RESOURCE_PATH_LENGTH];

    new JSON:iSoundsDoc = json_object_get_value(iSoundDoc, szKey, true);
    new Array:irgSounds = ArrayGetCell(Array:g_rgCharactersData[iCharacterData], iCharacter);
    new iSize = json_array_get_count(iSoundsDoc);

    if (ArraySize(irgSounds)) {
        ArrayClear(irgSounds);
    }

    for (new i = 0; i < iSize; ++i) {
        json_array_get_string(iSoundsDoc, i, szBuffer, charsmax(szBuffer));
        ArrayPushString(irgSounds, szBuffer);
        precache_sound(szBuffer);
    }
}

InitializeCharactersStore() {
    g_iCharactersMap = TrieCreate();
    g_iSelectableCharacters = ArrayCreate(_, RESERVED_CHARACTER_COUNT);

    g_rgCharactersData[Character_HumanModel] = ArrayCreate(MAX_RESOURCE_PATH_LENGTH, RESERVED_CHARACTER_COUNT);
    g_rgCharactersData[Character_ZombieModel] = ArrayCreate(MAX_RESOURCE_PATH_LENGTH, RESERVED_CHARACTER_COUNT);
    g_rgCharactersData[Character_SwipeModel] = ArrayCreate(MAX_RESOURCE_PATH_LENGTH, RESERVED_CHARACTER_COUNT);
    g_rgCharactersData[Character_HumanDeathSounds] = ArrayCreate(_, RESERVED_CHARACTER_COUNT);
    g_rgCharactersData[Character_PanicSounds] = ArrayCreate(_, RESERVED_CHARACTER_COUNT);
    g_rgCharactersData[Character_ZombieAmbientSounds] = ArrayCreate(_, RESERVED_CHARACTER_COUNT);
    g_rgCharactersData[Character_ZombieDeathSounds] = ArrayCreate(_, RESERVED_CHARACTER_COUNT);
    g_rgCharactersData[Character_IsSelectable] = ArrayCreate(_, RESERVED_CHARACTER_COUNT);
    g_rgCharactersData[Character_BodyIndex] = ArrayCreate(_, RESERVED_CHARACTER_COUNT);
}

DestroyCharactersStore() {
    for (new iCharacter; iCharacter < g_iCharacterCount; ++iCharacter) {
        DestroyCharacter(iCharacter);
    }

    TrieDestroy(g_iCharactersMap);
    ArrayDestroy(g_iSelectableCharacters);

    ArrayDestroy(Array:g_rgCharactersData[Character_HumanModel]);
    ArrayDestroy(Array:g_rgCharactersData[Character_ZombieModel]);
    ArrayDestroy(Array:g_rgCharactersData[Character_SwipeModel]);
    ArrayDestroy(Array:g_rgCharactersData[Character_HumanDeathSounds]);
    ArrayDestroy(Array:g_rgCharactersData[Character_PanicSounds]);
    ArrayDestroy(Array:g_rgCharactersData[Character_ZombieAmbientSounds]);
    ArrayDestroy(Array:g_rgCharactersData[Character_ZombieDeathSounds]);
}
