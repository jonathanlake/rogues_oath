extends Node

## The host populates this before starting the server. All game systems read from it.
var config: GameConfig = GameConfig.new()

## Set from the main menu before host_game() / join_game(). Flows into the spawn
## dict so all peers know each player's display name independently of peer ID.
var player_name: String = ""
