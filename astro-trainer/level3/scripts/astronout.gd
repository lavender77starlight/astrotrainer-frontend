extends Sprite2D

var speed = 300.0
@onready var step_sound = $stepsound

func _process(delta):
	var is_moving = false
	
	if Input.is_action_pressed("ui_right"):
		position.x += speed * delta
		flip_h = false
		is_moving = true

	if Input.is_action_pressed("ui_left"):
		position.x -= speed * delta
		flip_h = true
		is_moving = true

	if is_moving:
		if not step_sound.playing:
			step_sound.play()
	else:
		step_sound.stop()

	position.x = clamp(position.x, 50, 1230)