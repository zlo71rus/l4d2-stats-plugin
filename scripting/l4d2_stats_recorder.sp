#pragma semicolon 1
#pragma newdecls required

//#define DEBUG 0
#define PLUGIN_VERSION "1.0"

#include <sourcemod>
#include <sdktools>
#include <geoip>
#include <sdkhooks>
#include "jutils.inc"
#include <left4dhooks>

#undef REQUIRE_PLUGIN
#include <l4d2_skill_detect>
//#include <sdkhooks>

public Plugin myinfo = 
{
	name =  "L4D(2) Stats Recorder", 
	author = "jackzmc", 
	description = "", 
	version = PLUGIN_VERSION, 
	url = ""
};
static ConVar hServerTags, hZDifficulty;
static Database g_db;
static char steamidcache[MAXPLAYERS+1][32];
bool lateLoaded = false, bVersus, bRealism;
static char gamemode[32], serverTags[255], uuid[64];
static bool campaignFinished, skillDetectAvailable; //Has finale started?
static int iZDifficulty; //On finale_start populated with z_difficulty

//Stats that need to be only sent periodically. (note: possibly deaths?)
static int damageSurvivorGiven[MAXPLAYERS+1];
static int damageInfectedGiven[MAXPLAYERS+1];
static int damageInfectedRec[MAXPLAYERS+1];
static int damageSurvivorFF[MAXPLAYERS+1];
static int doorOpens[MAXPLAYERS+1];
static int witchKills[MAXPLAYERS+1];
static int startedPlaying[MAXPLAYERS+1];
static int points[MAXPLAYERS+1];
static int upgradePacksDeployed[MAXPLAYERS+1];
static int finaleTimeStart;
static int molotovDamage[MAXPLAYERS+1];
static int pipeKills[MAXPLAYERS+1];
static int molotovKills[MAXPLAYERS+1];
static int minigunKills[MAXPLAYERS+1];
static int iGameStartTime;
//Used for table: stats_games
static int m_checkpointZombieKills[MAXPLAYERS+1];
static int m_checkpointSurvivorDamage[MAXPLAYERS+1];
static int m_checkpointMedkitsUsed[MAXPLAYERS+1];
static int m_checkpointPillsUsed[MAXPLAYERS+1];
static int m_checkpointMolotovsUsed[MAXPLAYERS+1];
static int m_checkpointPipebombsUsed[MAXPLAYERS+1];
static int m_checkpointBoomerBilesUsed[MAXPLAYERS+1];
static int m_checkpointAdrenalinesUsed[MAXPLAYERS+1];
static int m_checkpointDefibrillatorsUsed[MAXPLAYERS+1];
static int m_checkpointDamageTaken[MAXPLAYERS+1];
static int m_checkpointReviveOtherCount[MAXPLAYERS+1];
static int m_checkpointFirstAidShared[MAXPLAYERS+1];
static int m_checkpointIncaps[MAXPLAYERS+1];
static int m_checkpointAccuracy[MAXPLAYERS+1];
static int m_checkpointDeaths[MAXPLAYERS+1];
static int m_checkpointMeleeKills[MAXPLAYERS+1];
static int sBoomerKills[MAXPLAYERS+1];
static int sSmokerKills[MAXPLAYERS+1];
static int sJockeyKills[MAXPLAYERS+1];
static int sHunterKills[MAXPLAYERS+1];
static int sSpitterKills[MAXPLAYERS+1];
static int sChargerKills[MAXPLAYERS+1];
//add:  	m_checkpointDamageToTank
//add:  	m_checkpointDamageToWitch

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) {
	if(late) lateLoaded = true;
}
//TODO: player_use (Check laser sights usage)
//TODO: Witch startles
//TODO: Versus as infected stats
//TODO: Move kills to queue stats not on demand
//TODO: map_stats record fastest timestamp

public void OnPluginStart()
{
	EngineVersion g_Game = GetEngineVersion();
	if(g_Game != Engine_Left4Dead && g_Game != Engine_Left4Dead2)
	{
		SetFailState("This plugin is for L4D/L4D2 only.");	
	}
	if(!SQL_CheckConfig("stats")) {
		SetFailState("No database entry for 'stats'; no database to connect to.");
	}
	if(!ConnectDB()) {
		SetFailState("Failed to connect to database.");
	}

	if(lateLoaded) {
		//If plugin late loaded, grab all real user's steamids again, then recreate user
		for(int i = 1; i <= MaxClients; i++) {
			if(IsClientConnected(i) && IsClientInGame(i) && !IsFakeClient(i)) {
				char steamid[32];
				GetClientAuthId(i, AuthId_Steam2, steamid, sizeof(steamid));
				strcopy(steamidcache[i], 32, steamid);
				//Recreate user (grabs points, so it won't reset)
				SetupUserInDB(i, steamid);
			}
		}
	}

	hServerTags = CreateConVar("l4d2_statsrecorder_tags", "", "A comma-seperated list of tags that will be used to identity this server.");
	hServerTags.GetString(serverTags, sizeof(serverTags));
	hServerTags.AddChangeHook(CVC_TagsChanged);

	ConVar hGamemode = FindConVar("mp_gamemode");
	hGamemode.GetString(gamemode, sizeof(gamemode));
	hGamemode.AddChangeHook(CVC_GamemodeChange);

	hZDifficulty = FindConVar("z_difficulty");

	//Hook all events to track statistics
	HookEvent("player_death", Event_PlayerDeath);
	HookEvent("player_hurt", Event_PlayerHurt);
	HookEvent("player_incapacitated", Event_PlayerIncap);
	HookEvent("pills_used", Event_ItemUsed);
	HookEvent("defibrillator_used", Event_ItemUsed);
	HookEvent("adrenaline_used", Event_ItemUsed);
	HookEvent("heal_success", Event_ItemUsed);
	HookEvent("revive_success", Event_ItemUsed); //Yes it's not an item. No I don't care.
	HookEvent("melee_kill", Event_MeleeKill);
	HookEvent("tank_killed", Event_TankKilled);
	HookEvent("witch_killed", Event_WitchKilled);
	HookEvent("infected_hurt", Event_InfectedHurt);
	HookEvent("infected_death", Event_InfectedDeath);
	HookEvent("door_open", Event_DoorOpened);
	HookEvent("upgrade_pack_used", Event_UpgradePackUsed);
	//Used for campaign recording:
	HookEvent("finale_start", Event_FinaleStart);
	HookEvent("gauntlet_finale_start", Event_FinaleStart);
	HookEvent("finale_vehicle_ready", Event_FinaleVehicleReady);
	HookEvent("finale_win", Event_FinaleWin);
	HookEvent("hegrenade_detonate", Event_GrenadeDenonate);
	//Used to transition checkpoint statistics for stats_games
	HookEvent("game_start", Event_GameStart);
	HookEvent("round_end", Event_RoundEnd);
	HookEvent("map_transition", Event_MapTransition);
	#if defined DEBUG
	RegConsoleCmd("sm_debug_stats", Command_DebugStats, "Debug stats");
	#endif
	//CreateTimer(60.0, Timer_FlushStats, _, TIMER_REPEAT);

	AutoExecConfig(true, "l4d2_stats_recorder");
}

//When plugin is being unloaded: flush all user's statistics.
public void OnPluginEnd() {
	for(int i=1; i<=MaxClients;i++) {
		if(IsClientConnected(i) && IsClientInGame(i) && !IsFakeClient(i) && steamidcache[i][0]) {
			FlushQueuedStats(i, false);
		}
	}
}
//Check if l4d2_skill_detect exists, for some extra skills.
public void OnAllPluginsLoaded() {
	skillDetectAvailable = LibraryExists("skill_detect");
}
public void OnLibraryRemoved(const char[] name) {
    if (StrEqual(name, "skill_detect"))
        skillDetectAvailable = false;
    
}
 
public void OnLibraryAdded(const char[] name) {
    if (StrEqual(name, "skill_detect"))
		skillDetectAvailable = true;
}
 
//////////////////////////////////
// TIMER
/////////////////////////////////
public Action Timer_FlushStats(Handle timer) {
	//Periodically flush the statistics
	if(GetClientCount(true) > 0) {
		for(int i=1; i<=MaxClients;i++) {
			if(IsClientConnected(i) && IsClientInGame(i) && !IsFakeClient(i) && steamidcache[i][0]) {
				FlushQueuedStats(i, false);
			}
		}
	}
}
/////////////////////////////////
// CONVAR CHANGES
/////////////////////////////////
public void CVC_GamemodeChange(ConVar convar, const char[] oldValue, const char[] newValue) {
	strcopy(gamemode, sizeof(gamemode), newValue);
}
public void CVC_TagsChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
	strcopy(serverTags, sizeof(serverTags), newValue);
}
/////////////////////////////////
// PLAYER AUTH
/////////////////////////////////
public void OnClientAuthorized(int client, const char[] auth) {
	if(client > 0 && !IsFakeClient(client)) {
		strcopy(steamidcache[client], 32, auth);
		SetupUserInDB(client, steamidcache[client]);
	}
}
public void OnClientDisconnect(int client) {
	//Check if any pending stats to send.
	if(!IsFakeClient(client) && IsClientInGame(client)) {
		//Record campaign session, incase they leave early. 
		//Should only fire if disconnects after escape_vehicle_ready and before finale_win (credits screen)
		if(campaignFinished && uuid[0] && steamidcache[client][0]) {
			IncrementSessionStat(client);
			RecordCampaign(client);
			IncrementStat(client, "finales_won", 1);
			points[client] += 400;
		}

		FlushQueuedStats(client, true);
		steamidcache[client][0] = '\0';
		points[client] = 0;

		//ResetSessionStats(client); //Can't reset session stats cause transitions!
	}
}

///////////////////////////////////
//DB METHODS
//////////////////////////////////

bool ConnectDB() {
    char error[255];
    g_db = SQL_Connect("stats", true, error, sizeof(error));
    if (g_db == null) {
		LogError("Database error %s", error);
		delete g_db;
		return false;
    } else {
		PrintToServer("Connected to database stats");
		SQL_LockDatabase(g_db);
		SQL_FastQuery(g_db, "SET NAMES \"UTF8mb4\"");  
		SQL_UnlockDatabase(g_db);
		g_db.SetCharset("utf8mb4");
		return true;
    }
}
//Setups a user, this tries to fetch user by steamid
void SetupUserInDB(int client, const char steamid[32]) {
	if(client > 0 && !IsFakeClient(client)) {
		startedPlaying[client] = GetTime();
		char query[128];
		Format(query, sizeof(query), "SELECT last_alias,points FROM stats_users WHERE steamid='%s'", steamid);
		SQL_TQuery(g_db, DBCT_CheckUserExistance, query, GetClientUserId(client));
	}
}
//Increments a statistic by X amount
void IncrementStat(int client, const char[] name, int amount = 1, bool lowPriority = false, bool retry = true) {
	if(client > 0 && !IsFakeClient(client) && IsClientConnected(client)) {
		//Only run if client valid client, AND has steamid. Not probably necessarily anymore.
		if (steamidcache[client][0]) {
			if(g_db == INVALID_HANDLE) {
				LogError("Database handle is invalid.");
				return;
			}
			int escaped_name_size = 2*strlen(name)+1;
			char[] escaped_name = new char[escaped_name_size];
			char query[255];
			g_db.Escape(name, escaped_name, escaped_name_size);
			Format(query, sizeof(query), "UPDATE stats_users SET `%s`=`%s`+%d WHERE steamid='%s'", escaped_name, escaped_name, amount, steamidcache[client]);
			#if defined DEBUG
			PrintToServer("[Debug] Updating Stat %s (+%d) for %N (%d) [%s]", name, amount, client, client, steamidcache[client]);
			#endif 
			SQL_TQuery(g_db, DBCT_Generic, query, _, lowPriority ? DBPrio_Low : DBPrio_Normal);
		}else{
			//Incase user does not have a steamid in the cache: to prevent stat loss, fetch steamid and retry.
			#if defined DEBUG
			LogError("Incrementing stat (%s) for client %N (%d) [%s] failure: No steamid or is bot", name, client, client, steamidcache[client]);
			#endif
			//attempt to fetch it
			char steamid[32];
			GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid));
			steamidcache[client] = steamid;
			if(retry) {
				IncrementStat(client, name, amount, lowPriority, false);
			}
		}
	}
}

void RecordCampaign(int client) {
	if (client > 0 && IsClientConnected(client) && IsClientInGame(client)) {
		char query[1023], mapname[127];
		GetCurrentMap(mapname, sizeof(mapname));

		if(m_checkpointZombieKills[client] == 0) {
			PrintToServer("Warn: Client %N for %s | 0 zombie kills", client, uuid);
		}

		char model[64];
		GetClientModel(client, model, sizeof(model));

		int finaleTimeTotal = (finaleTimeStart > 0) ? GetTime() - finaleTimeStart : 0;
		Format(query, sizeof(query), "INSERT INTO stats_games (`steamid`, `map`, `gamemode`,`campaignID`, `finale_time`, `date_start`,`date_end`, `zombieKills`, `survivorDamage`, `MedkitsUsed`, `PillsUsed`, `MolotovsUsed`, `PipebombsUsed`, `BoomerBilesUsed`, `AdrenalinesUsed`, `DefibrillatorsUsed`, `DamageTaken`, `ReviveOtherCount`, `FirstAidShared`, `Incaps`, `Deaths`, `MeleeKills`, `difficulty`, `ping`,`boomer_kills`,`smoker_kills`,`jockey_kills`,`hunter_kills`,`spitter_kills`,`charger_kills`,`server_tags`,`characterType`) VALUES ('%s','%s','%s','%s',%d,%d,UNIX_TIMESTAMP(),%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,'%s',%d)",
			steamidcache[client],
			mapname,
			gamemode,
			uuid,
			finaleTimeTotal,
			iGameStartTime,
			//unix_timestamp(),
			m_checkpointZombieKills[client],
			m_checkpointSurvivorDamage[client],
			m_checkpointMedkitsUsed[client],
			m_checkpointPillsUsed[client],
			m_checkpointMolotovsUsed[client],
			m_checkpointPipebombsUsed[client],
			m_checkpointBoomerBilesUsed[client],
			m_checkpointAdrenalinesUsed[client],
			m_checkpointDefibrillatorsUsed[client],
			m_checkpointDamageTaken[client],
			m_checkpointReviveOtherCount[client],
			m_checkpointFirstAidShared[client],
			m_checkpointIncaps[client],
			m_checkpointDeaths[client],
			m_checkpointMeleeKills[client],
			iZDifficulty,
			GetEntProp(GetPlayerResourceEntity(), Prop_Send, "m_iPing", _, client), //record user ping
			sBoomerKills[client],
			sSmokerKills[client],
			sJockeyKills[client],
			sHunterKills[client],
			sSpitterKills[client],
			sChargerKills[client],
			serverTags,
			GetSurvivorType(model)
		);
		SQL_LockDatabase(g_db);
		bool result = SQL_FastQuery(g_db, query);
		SQL_UnlockDatabase(g_db);
		if(!result) {
			char error[128];
			SQL_GetError(g_db, error, sizeof(error));
			LogError("[l4d2_stats_recorder] RecordCampaign for %d failed. UUID %s | Query: `%s` | Error: %s", uuid, client, query, error);
		}
		#if defined DEBUG
			PrintToServer("[l4d2_stats_recorder] DEBUG: Added finale (%s) to stats_maps for %s ", mapname, steamidcache[client]);
		#endif
	}
}
//Flushes all the tracked statistics, and runs UPDATE SQL query on user. Then resets the variables to 0
public void FlushQueuedStats(int client, bool disconnect) {
	//Update stats (don't bother checking if 0.)
	int minutes_played = (GetTime() - startedPlaying[client]) / 60;
	//Incase somehow startedPlaying[client] not set (plugin reloaded?), defualt to 0
	if(minutes_played >= 2147483645) {
		startedPlaying[client] = GetTime();
		minutes_played = 0;
	}
	//Prevent points from being reset by not recording until user has gotten a point. 
	if(points[client] > 0) {
		char query[1023];
		Format(query, sizeof(query), "UPDATE stats_users SET survivor_damage_give=survivor_damage_give+%d,survivor_damage_rec=survivor_damage_rec+%d, infected_damage_give=infected_damage_give+%d,infected_damage_rec=infected_damage_rec+%d,survivor_ff=survivor_ff+%d,common_kills=common_kills+%d,common_headshots=common_headshots+%d,melee_kills=melee_kills+%d,door_opens=door_opens+%d,damage_to_tank=damage_to_tank+%d, damage_witch=damage_witch+%d,minutes_played=minutes_played+%d, kills_witch=kills_witch+%d, points=%d, packs_used=packs_used+%d, damage_molotov=damage_molotov+%d, kills_molotov=kills_molotov+%d, kills_pipe=kills_pipe+%d, kills_minigun=kills_minigun+%d WHERE steamid='%s'",
			damageSurvivorGiven[client], 								//survivor_damage_give
			GetEntProp(client, Prop_Send, "m_checkpointDamageTaken"),   //survivor_damage_rec
			damageInfectedGiven[client],  							    //infected_damage_give
			damageInfectedRec[client],   								//infected_damage_rec
			damageSurvivorFF[client],    								//survivor_ff
			GetEntProp(client, Prop_Send, "m_checkpointZombieKills"), 	//common_kills
			GetEntProp(client, Prop_Send, "m_checkpointHeadshots"),   	//common_headshots
			GetEntProp(client, Prop_Send, "m_checkpointMeleeKills"),  	//melee_kills
			doorOpens[client], 											//door_opens
			GetEntProp(client, Prop_Send, "m_checkpointDamageToTank"),  //damage_to_tank
			GetEntProp(client, Prop_Send, "m_checkpointDamageToWitch"), //damage_witch
			minutes_played, 											//minutes_played
			witchKills[client], 										//kills_witch
			points[client], 											//points
			upgradePacksDeployed[client], 								//packs_used
			molotovDamage[client], 										//damage_molotov
			pipeKills[client], 											//kills_pipe,
			molotovKills[client],										//kills_molotov
			minigunKills[client],										//kills_minigun
			steamidcache[client][0]
		);
		if(disconnect) {
			SQL_LockDatabase(g_db);
			SQL_FastQuery(g_db, query);
			SQL_UnlockDatabase(g_db);
			ResetInternal(client, true);
		}else{
			SQL_TQuery(g_db, DBCT_FlushQueuedStats, query, client);
		}
		//And clear them.
	}
}
//Record a special kill to local variable
void IncrementSpecialKill(int client, int special) {
	switch(special) {
		case 1: sSmokerKills[client]++;
		case 2: sBoomerKills[client]++;
		case 3: sHunterKills[client]++;
		case 4: sSpitterKills[client]++;
		case 5: sJockeyKills[client]++;
		case 6: sChargerKills[client]++;
	}
}
void ResetSessionStats(int i, bool resetAll) {
	m_checkpointZombieKills[i] =			0;
	m_checkpointSurvivorDamage[i] = 		0;
	m_checkpointMedkitsUsed[i] = 			0;
	m_checkpointPillsUsed[i] = 				0;
	m_checkpointMolotovsUsed[i] = 			0;
	m_checkpointPipebombsUsed[i] = 			0;
	m_checkpointBoomerBilesUsed[i] = 		0;
	m_checkpointAdrenalinesUsed[i] = 		0;
	m_checkpointDefibrillatorsUsed[i] = 	0;
	m_checkpointDamageTaken[i] =			0;
	m_checkpointReviveOtherCount[i] = 		0;
	m_checkpointFirstAidShared[i] = 		0;
	m_checkpointIncaps[i]  = 				0;
	if(resetAll) 
		m_checkpointDeaths[i] = 				0;
	m_checkpointMeleeKills[i] = 			0;
	sBoomerKills[i]  = 0;
	sSmokerKills[i]  = 0;
	sJockeyKills[i]  = 0;
	sHunterKills[i]  = 0;
	sSpitterKills[i] = 0;
	sChargerKills[i] = 0;
}
void IncrementSessionStat(int i) {
	m_checkpointZombieKills[i] += 			GetEntProp(i, Prop_Send, "m_checkpointZombieKills");
	m_checkpointSurvivorDamage[i] += 		damageSurvivorFF[i];
	m_checkpointMedkitsUsed[i] += 			GetEntProp(i, Prop_Send, "m_checkpointMedkitsUsed");
	m_checkpointPillsUsed[i] += 			GetEntProp(i, Prop_Send, "m_checkpointPillsUsed");
	m_checkpointMolotovsUsed[i] += 			GetEntProp(i, Prop_Send, "m_checkpointMolotovsUsed");
	m_checkpointPipebombsUsed[i] += 		GetEntProp(i, Prop_Send, "m_checkpointPipebombsUsed");
	m_checkpointBoomerBilesUsed[i] += 		GetEntProp(i, Prop_Send, "m_checkpointBoomerBilesUsed");
	m_checkpointAdrenalinesUsed[i] += 		GetEntProp(i, Prop_Send, "m_checkpointAdrenalinesUsed");
	m_checkpointDefibrillatorsUsed[i] += 	GetEntProp(i, Prop_Send, "m_checkpointDefibrillatorsUsed");
	m_checkpointDamageTaken[i] +=			GetEntProp(i, Prop_Send, "m_checkpointDamageTaken");
	m_checkpointReviveOtherCount[i] += 		GetEntProp(i, Prop_Send, "m_checkpointReviveOtherCount");
	m_checkpointFirstAidShared[i] += 		GetEntProp(i, Prop_Send, "m_checkpointFirstAidShared");
	m_checkpointIncaps[i]  += 				GetEntProp(i, Prop_Send, "m_checkpointIncaps");
	m_checkpointDeaths[i] += 				GetEntProp(i, Prop_Send, "m_checkpointDeaths");
	m_checkpointMeleeKills[i] += 			GetEntProp(i, Prop_Send, "m_checkpointMeleeKills");
	PrintToServer("[l4d2_stats_recorder] Incremented checkpoint stats for %N", i);
}

/////////////////////////////////
//DATABASE CALLBACKS
/////////////////////////////////
//Handles the CreateDBUser() response. Either updates alias and stores points, or creates new SQL user.
public void DBCT_CheckUserExistance(Handle db, Handle queryHandle, const char[] error, any data) {
	if(db == INVALID_HANDLE || queryHandle == INVALID_HANDLE) {
        LogError("DBCT_CheckUserExistance returned error: %s", error);
        return;
    }
	//initialize variables
	int client = GetClientOfUserId(data); 
	int alias_length = 2*MAX_NAME_LENGTH+1;
	char alias[MAX_NAME_LENGTH], ip[40], country_name[45];
	char[] safe_alias = new char[alias_length];

	//Get a SQL-safe player name, and their counttry and IP
	GetClientName(client, alias, sizeof(alias));
	SQL_EscapeString(g_db, alias, safe_alias, alias_length);
	GetClientIP(client, ip, sizeof(ip));
	GeoipCountry(ip, country_name, sizeof(country_name));

	if(SQL_GetRowCount(queryHandle) == 0) {
		//user does not exist in db, create now

		char query[255]; 
		Format(query, sizeof(query), "INSERT INTO `stats_users` (`steamid`, `last_alias`, `last_join_date`,`created_date`,`country`) VALUES ('%s', '%s', UNIX_TIMESTAMP(), UNIX_TIMESTAMP(), '%s')", steamidcache[client], safe_alias, country_name);
		SQL_TQuery(g_db, DBCT_Generic, query);
		PrintToServer("[l4d2_stats_recorder] Created new database entry for %N (%s)", client, steamidcache[client]);
	}else{
		//User does exist, check if alias is outdated and update some columns (last_join_date, country, connections, or last_alias)
		while(SQL_FetchRow(queryHandle)) {
			int field_num;
			if(SQL_FieldNameToNum(queryHandle, "points", field_num)) {
				points[client] = SQL_FetchInt(queryHandle, field_num);
			}
		}
		if(points[client] == 0) {
			PrintToServer("[l4d2_stats_recorder] Warning: Existing player %N (%d) has no points", client, client);
		}
		char query[255];
		int connections_amount = lateLoaded ? 0 : 1;

		Format(query, sizeof(query), "UPDATE `stats_users` SET `last_alias`='%s', `last_join_date`=UNIX_TIMESTAMP(), `country`='%s', connections=connections+%d WHERE `steamid`='%s'", safe_alias, country_name, connections_amount, steamidcache[client]);
		SQL_TQuery(g_db, DBCT_Generic, query);
	}
}
//Generic database response that logs error
public void DBCT_Generic(Handle db, Handle child, const char[] error, any data)
{
    if(db == null || child == null) {
		if(data) {
        	LogError("DBCT_Generic query `%s` returned error: %s", data, error);
		}else {
			LogError("DBCT_Generic returned error: %s", error);
		}
    }
}
public void DBCT_GetUUIDForCampaign(Handle db, Handle results, const char[] error, any data) {
	if(results != INVALID_HANDLE && SQL_GetRowCount(results) > 0) {
		SQL_FetchRow(results);
		SQL_FetchString(results, 0, uuid, sizeof(uuid));
		PrintToServer("UUID for campaign: %s | Difficulty: %d", uuid, iZDifficulty);
	}else{
		LogError("RecordCampaign, failed to get UUID: %s", error);
	}
}
//After a user's stats were flushed, reset any statistics needed to zero.
public void DBCT_FlushQueuedStats(Handle db, Handle child, const char[] error, int client) {
	if(db == INVALID_HANDLE || child == INVALID_HANDLE) {
		LogError("DBCT_FlushQueuedStats returned error: %s", error);
	}else{
		ResetInternal(client, false);
	}
}
public void ResetInternal(int client, bool disconnect) {
	damageSurvivorFF[client] = 0;
	damageSurvivorGiven[client] = 0;
	doorOpens[client] = 0;
	witchKills[client] = 0;
	upgradePacksDeployed[client] = 0;
	molotovDamage[client] = 0;
	pipeKills[client] = 0;
	molotovKills[client] = 0;
	minigunKills[client] = 0;
	if(!disconnect)
		startedPlaying[client] = GetTime();
}
////////////////////////////
// COMMANDS
///////////////////////////
#if defined DEBUG
public Action Command_DebugStats(int client, int args) {
	if(client == 0 && !IsDedicatedServer()) {
		ReplyToCommand(client, "This command must be used as a player.");
	}else {
		ReplyToCommand(client, "Statistics for %s", steamidcache[client]);
		ReplyToCommand(client, "m_checkpointAdrenalinesUsed %d", GetEntProp(client, Prop_Send, " m_checkpointAdrenalinesUsed"));
		ReplyToCommand(client, "m_checkpointAdrenalinesUsed[client] %d", m_checkpointAdrenalinesUsed[client]);
		ReplyToCommand(client, "damageSurvivorGiven %d", damageSurvivorGiven[client]); 
		ReplyToCommand(client, "m_checkpointDamageTaken %d", GetEntProp(client, Prop_Send, "m_checkpointDamageTaken"));
		ReplyToCommand(client, "m_checkpointDamageTaken[client]: %d", m_checkpointDamageTaken[client]);
		ReplyToCommand(client, "points = %d", points[client]);
	}
	return Plugin_Handled;
}
#endif

////////////////////////////
// EVENTS 
////////////////////////////
//Records the amount of HP done to infected (zombies)
public void Event_InfectedHurt(Event event, const char[] name, bool dontBroadcast) {
	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	if(attacker > 0 && !IsFakeClient(attacker)) {
		int dmg = event.GetInt("amount");
		damageSurvivorGiven[attacker] += dmg;
	}
}
public void Event_InfectedDeath(Event event, const char[] name, bool dontBroadcast) {
	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	if(attacker > 0 && !IsFakeClient(attacker)) {
		bool blast = event.GetBool("blast");
		bool headshot = event.GetBool("headshot");
		bool using_minigun = event.GetBool("minigun");
		char wpn_name[32];
		GetClientWeapon(attacker, wpn_name, sizeof(wpn_name));

		if(headshot) {
			points[attacker]+=2;
		}else{
			points[attacker]++;
		}
		if(using_minigun) {
			minigunKills[attacker]++;
		}else if(blast) {
			pipeKills[attacker]++;
		}
	}
}
public void Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast) {
	int victim = GetClientOfUserId(event.GetInt("userid"));
	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	int victim_team = GetClientTeam(victim);
	int dmg = event.GetInt("dmg_health");
	if(dmg <= 0) return;
	if(attacker > 0 && !IsFakeClient(attacker)) {
		int attacker_team = GetClientTeam(attacker);
		char wpn_name[32]; 
		event.GetString("weapon", wpn_name, sizeof(wpn_name));

		if(attacker_team == 2) {
			damageSurvivorGiven[attacker] += dmg;

			if(victim_team == 3 && StrEqual(wpn_name, "inferno", true)) {
				molotovDamage[attacker] += dmg;
				points[attacker]++; //give points (not per dmg tho)
			}
		}else if(attacker_team == 3) {
			damageInfectedGiven[attacker] += dmg;
		}
		if(attacker_team == 2 && victim_team == 2) {
			points[attacker]--;
			damageSurvivorFF[attacker] += dmg;
		}
	}
}
public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast) {
	int victim = GetClientOfUserId(event.GetInt("userid"));
	if(victim > 0) {
		int attacker = GetClientOfUserId(event.GetInt("attacker"));
		int victim_team = GetClientTeam(victim);

		if(!IsFakeClient(victim)) {
			if(victim_team == 2) {
				IncrementStat(victim, "survivor_deaths", 1);
			}
		}

		if(attacker > 0 && !IsFakeClient(attacker) && GetClientTeam(attacker) == 2) {
			if(victim_team == 3) {
				int victim_class = GetEntProp(victim, Prop_Send, "m_zombieClass");
				char class[8], statname[16], wpn_name[32]; 
				event.GetString("weapon", wpn_name, sizeof(wpn_name));

				if(GetInfectedClassName(victim_class, class, sizeof(class))) {
					IncrementSpecialKill(attacker, victim_class);
					Format(statname, sizeof(statname), "kills_%s", class);
					IncrementStat(attacker, statname, 1);
					points[attacker] += 5; //special kill
				}
				if(StrEqual(wpn_name, "inferno", true) || StrEqual(wpn_name, "entityflame", true)) {
					molotovKills[attacker]++;
				}
				IncrementStat(victim, "infected_deaths", 1);
			}else if(victim_team == 2) {
				IncrementStat(attacker, "ff_kills", 1);
				points[attacker] -= 30; //30 point lost for killing teammate
			}
		}
	}
	
}
public void Event_MeleeKill(Event event, const char[] name, bool dontBroadcast) {
	int client = GetClientOfUserId(event.GetInt("userid"));
	if(client > 0 && !IsFakeClient(client)) {
		points[client]++;
	}
}
public void Event_TankKilled(Event event, const char[] name, bool dontBroadcast) {
	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	int solo = event.GetBool("solo") ? 1 : 0;
	int melee_only = event.GetBool("melee_only") ? 1 : 0;

	if(attacker > 0 && !IsFakeClient(attacker)) {
		if(solo) {
			points[attacker] += 100;
			IncrementStat(attacker, "tanks_killed_solo", 1);
		}
		if(melee_only) {
			points[attacker] += 150;
			IncrementStat(attacker, "tanks_killed_melee", 1);
		}
		points[attacker] += 200;
		IncrementStat(attacker, "tanks_killed", 1);
	}
}
public void Event_DoorOpened(Event event, const char[] name, bool dontBroadcast) {
	int client = GetClientOfUserId(event.GetInt("userid"));
	if(client > 0 && event.GetBool("closed") && !IsFakeClient(client)) {
		doorOpens[client]++;

	}
}
//Records anytime an item is picked up. Runs for any weapon, only a few have a SQL column. (Throwables)
public void Event_ItemPickup(Event event, const char[] name, bool dontBroadcast) {
	char statname[72], item[64];

	int client = GetClientOfUserId(event.GetInt("userid"));
	if(!IsFakeClient(client)) {
		event.GetString("item", item, sizeof(item));
		ReplaceString(item, sizeof(item), "weapon_", "", true);
		Format(statname, sizeof(statname), "pickups_%s", item);
		IncrementStat(client, statname, 1);
	}
}
public void Event_PlayerIncap(Event event, const char[] name, bool dontBroadcast) {
	int client = GetClientOfUserId(event.GetInt("userid"));
	if(!IsFakeClient(client) && GetClientTeam(client) == 2) {
		IncrementStat(client, "survivor_incaps", 1);
	}
}
//Track heals, or defibs
public void Event_ItemUsed(Event event, const char[] name, bool dontBroadcast) {
	int client = GetClientOfUserId(event.GetInt("userid"));
	if(client > 0 && !IsFakeClient(client)) {
		if(StrEqual(name, "heal_success", true)) {
			int subject = GetClientOfUserId(event.GetInt("subject"));
			if(subject == client) {
				IncrementStat(client, "heal_self", 1);
			}else{
				points[client] += 10;
				IncrementStat(client, "heal_others", 1);
			}
		}else if(StrEqual(name, "revive_success", true)) {
			int subject = GetClientOfUserId(event.GetInt("subject"));
			if(subject != client) {
				IncrementStat(client, "revived_others", 1);
				points[client] += 3;
				IncrementStat(subject, "revived", 1);
			}
		}else if(StrEqual(name, "defibrillator_used", true)) {
			points[client]+=9;
			IncrementStat(client, "defibs_used", 1);
		}else{
			IncrementStat(client, name, 1);
		}
	}
}

public void Event_UpgradePackUsed(Event event, const char[] name, bool dontBroadcast) {
	int client = GetClientOfUserId(event.GetInt("userid"));
	if(client > 0 && !IsFakeClient(client)) {
		upgradePacksDeployed[client]++;
		points[client]+=3;
	}
}
public void Event_CarAlarm(Event event, const char[] name, bool dontBroadcast) {
	int client = GetClientOfUserId(event.GetInt("userid"));
	if(client > 0 && !IsFakeClient(client)) {
		IncrementStat(client, "caralarms_activated", 1);
	}
}
public void Event_WitchKilled(Event event, const char[] name, bool dontBroadcast) {
	int client = GetClientOfUserId(event.GetInt("userid"));
	if(client > 0 && !IsFakeClient(client)) {
		witchKills[client]++;
		points[client]+=100;
	}
}


public void Event_GrenadeDenonate(Event event, const char[] name, bool dontBroadcast) {
	int client = GetClientOfUserId(event.GetInt("userid"));
	if(client > 0 && !IsFakeClient(client)) {
		char wpn_name[32];
		GetClientWeapon(client, wpn_name, sizeof(wpn_name));
		//PrintToServer("wpn_Name %s", wpn_name);
		//Somehow have to check if molotov or gr
	}
}
///THROWABLE TRACKING
//This is used to track throwable throws 
public void OnEntityCreated(int entity) {
	char class[32];
	GetEntityClassname(entity, class, sizeof(class));
	if(StrContains(class, "_projectile", true) > -1 && HasEntProp(entity, Prop_Send, "m_hOwnerEntity")) {
		RequestFrame(EntityCreateCallback, entity);
	}
}
void EntityCreateCallback(int entity) {
	if(!HasEntProp(entity, Prop_Send, "m_hOwnerEntity") || !IsValidEntity(entity)) return;
	char class[16];

	GetEntityClassname(entity, class, sizeof(class));
	int entOwner = GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity");
	if(entOwner > 0) {
		if(StrContains(class, "vomitjar", true) > -1) {
			IncrementStat(entOwner, "throws_puke", 1);
		}else if(StrContains(class, "molotov", true) > -1) {
			IncrementStat(entOwner, "throws_molotov", 1);
		}else if(StrContains(class, "pipe_bomb", true) > -1) {
			IncrementStat(entOwner, "throws_pipe", 1);
		}
	}
}
bool isTransition = false;
////MAP EVENTS
public Action Event_GameStart(Event event, const char[] name, bool dontBroadcast) {
	iGameStartTime = GetTime();
	for(int i = 1; i <= MaxClients; i++) {
		if(IsClientConnected(i) && IsClientInGame(i) && GetClientTeam(i) == 2 && IsPlayerAlive(i)) {
			ResetSessionStats(i, true);
			FlushQueuedStats(i, false);
		}
	}
}
public void OnMapStart() {
	if(isTransition) {
		isTransition = false;
	}else{
		PrintToServer("[l4d2_stats_recorder] Started recording statistics");
		iGameStartTime = GetTime();
		iZDifficulty = GetDifficultyInt();
		for(int i = 1; i <= MaxClients; i++) {
			if(IsClientConnected(i) && IsClientInGame(i) && GetClientTeam(i) == 2 && IsPlayerAlive(i)) {
				ResetSessionStats(i, true);
				FlushQueuedStats(i, false);
			}
		}
	}
}
public void Event_MapTransition(Event event, const char[] name, bool dontBroadcast) {
	isTransition = true;
	for(int i = 1; i <= MaxClients; i++) {
		if(IsClientConnected(i) && IsClientInGame(i) && GetClientTeam(i) == 2 && IsPlayerAlive(i) && !IsFakeClient(i)) {
			IncrementSessionStat(i);
			FlushQueuedStats(i, false);
		}
	}
}
public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast) {
	PrintToServer("[l4d2_stats_recorder] round_end; flushing");
	campaignFinished = false;
	
	for(int i = 1; i <= MaxClients; i++) {
		if(IsClientConnected(i) && IsClientInGame(i) && GetClientTeam(i) == 2 && IsPlayerAlive(i)) {
			//ResetSessionStats(i, false);
			FlushQueuedStats(i, false);
		}
	}
}
/*Order of events:
finale_start: Gets UUID
escape_vehicle_ready: IF fired, sets var campaignFinished to true.
finale_win: Record all players, campaignFinished = false

if player disconnects && campaignFinished: record their session. Won't be recorded in finale_win
*/
//Fetch UUID from finale start, should be ready for events finale_win OR escape_vehicle_ready
public void Event_FinaleStart(Event event, const char[] name, bool dontBroadcast) {
	finaleTimeStart = GetTime();
	iZDifficulty = GetDifficultyInt();
	SQL_TQuery(g_db, DBCT_GetUUIDForCampaign, "SELECT UUID() AS UUID", _, DBPrio_High);
}
public Action Event_FinaleVehicleReady(Event event, const char[] name, bool dontBroadcast) {
	//Get UUID on finale_start
	if(L4D_IsMissionFinalMap()) {
		iZDifficulty = GetDifficultyInt();
		campaignFinished = true;
	}
}

public void Event_FinaleWin(Event event, const char[] name, bool dontBroadcast) {
	if(!L4D_IsMissionFinalMap()) return;
	iZDifficulty = event.GetInt("difficulty");
	campaignFinished = false;
	char shortID[9];
	StrCat(shortID, sizeof(shortID), uuid);

	for(int i = 1; i <= MaxClients; i++) {
		if(IsClientConnected(i) && IsClientInGame(i) && GetClientTeam(i) == 2) {
			int client = i;
			if(IsFakeClient(i)) {
				if(!HasEntProp(i, Prop_Send, "m_humanSpectatorUserID")) continue;
				client = GetClientOfUserId(GetEntPropEnt(i, Prop_Send, "m_humanSpectatorUserID"));
				//get real client
			}
			if(steamidcache[client][0]) {
				IncrementSessionStat(client);
				RecordCampaign(client);
				IncrementStat(client, "finales_won", 1);
				PrintToChat(client, "View this game's statistics at https://jackz.me/c/%s", shortID);
				points[client] += 400;
			}
		}
	}	
}
////////////////////////////
// FORWARD EVENTS
///////////////////////////
public void OnWitchCrown(int survivor, int damage) {
	IncrementStat(survivor, "witches_crowned", 1);
}
public void OnWitchHurt(int survivor, int damage, int chip) {
	IncrementStat(survivor, "witches_crowned_angry", 1);
}
public void OnSmokerSelfClear( int survivor, int smoker, bool withShove ) {
	IncrementStat(survivor, "smokers_selfcleared", 1);
}
public void OnTankRockEaten( int tank, int survivor ) {
	IncrementStat(survivor, "rocks_hitby", 1);
}
public void OnHunterDeadstop(int survivor, int hunter) {
	IncrementStat(survivor, "hunters_deadstopped", 1);
}
public void OnSpecialClear( int clearer, int pinner, int pinvictim, int zombieClass, float timeA, float timeB, bool withShove ) {
	IncrementStat(clearer, "cleared_pinned", 1);
	IncrementStat(pinvictim, "times_pinned", 1);
}

////////////////////////////
// STOCKS
///////////////////////////
//Simply prints the respected infected's class name based on their numeric id. (not client/user ID)
stock bool GetInfectedClassName(int type, char[] buffer, int bufferSize) {
	switch(type) {
		case 1: strcopy(buffer, bufferSize, "smoker");
		case 2: strcopy(buffer, bufferSize, "boomer");
		case 3: strcopy(buffer, bufferSize, "hunter");
		case 4: strcopy(buffer, bufferSize, "spitter");
		case 5: strcopy(buffer, bufferSize, "jockey");
		case 6: strcopy(buffer, bufferSize, "charger");
		default: return false;
	}
	return true;
}

stock int GetDifficultyInt() {
	char diff[16];
	hZDifficulty.GetString(diff, sizeof(diff));
	if(StrEqual(diff, "easy", false)) return 0;
	else if(StrEqual(diff, "hard", false)) return 2;
	else if(StrEqual(diff, "impossible", false)) return 3;
	else return 1;
}