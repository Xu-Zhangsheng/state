"""Reproducible state app icon. Run with Blender --background --python this_file."""
import bpy
import math
import os
from mathutils import Vector

ROOT = os.path.dirname(os.path.abspath(__file__))
bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete(use_global=False)

def material(name, color, metal=0, rough=.2, transmission=0, ior=1.46):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    m.node_tree.nodes.clear()
    p = m.node_tree.nodes.new('ShaderNodeBsdfPrincipled')
    output = m.node_tree.nodes.new('ShaderNodeOutputMaterial')
    m.node_tree.links.new(p.outputs['BSDF'], output.inputs['Surface'])
    p.inputs['Base Color'].default_value = (*color, 1)
    p.inputs['Metallic'].default_value = metal
    p.inputs['Roughness'].default_value = rough
    p.inputs['Transmission Weight'].default_value = transmission
    p.inputs['IOR'].default_value = ior
    return m

glass = material('Optical glass — solid, IOR 1.46', (.985, .994, 1), rough=.012, transmission=1)
rim_glass = material('Subtle clear perimeter glass — IOR 1.34', (1, 1, 1), rough=.025, transmission=1, ior=1.34)
silver = material('Satin silver pin cores', (.63, .69, .74), metal=.92, rough=.18)
white = material('White porcelain background', (1, 1, 1), rough=.32)
dark = material('Off-camera graphite reflection cards', (.025, .035, .047), rough=.65)
etch = material('Frosted floor of engraved lightning', (.51, .62, .69), metal=.18, rough=.22, transmission=.35)

def box(name, location, scale, mat, radius=.1):
    bpy.ops.mesh.primitive_cube_add(size=1, location=location)
    o = bpy.context.object
    o.name = name
    o.dimensions = scale
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    if radius:
        b = o.modifiers.new('Polished roundover', 'BEVEL')
        b.width = radius
        b.segments = 12
        bpy.context.view_layer.objects.active = o
        bpy.ops.object.modifier_apply(modifier=b.name)
    o.data.materials.append(mat)
    for p in o.data.polygons:
        p.use_smooth = True
    n = o.modifiers.new('Weighted face normals', 'WEIGHTED_NORMAL')
    n.keep_sharp = True
    return o

# The glass is true closed geometry, not a transparent surface decal.
body = box('CPU — solid refractive glass', (0, 0, .53), (3.6, 3.6, .78), glass, .30)

bolt_points = [(.37, 1.12), (-.68, -.10), (-.12, -.10), (-.36, -1.11), (.70, .24), (.11, .24)]
def bolt(name, low, high, mat=None):
    n = len(bolt_points)
    verts = [(x, y, z) for z in (low, high) for x, y in bolt_points]
    faces = [tuple(reversed(range(n))), tuple(range(n, 2*n))]
    faces += [(i, (i+1)%n, (i+1)%n+n, i+n) for i in range(n)]
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(verts, [], faces)
    mesh.update()
    ob = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(ob)
    if mat:
        mesh.materials.append(mat)
    return ob

cutter = bolt('Lightning engraving tool', .69, 1.3)
bpy.context.view_layer.objects.active = body
cut = body.modifiers.new('Actual recessed lightning cavity', 'BOOLEAN')
cut.operation = 'DIFFERENCE'
cut.solver = 'EXACT'
cut.object = cutter
bpy.ops.object.modifier_apply(modifier=cut.name)
bpy.data.objects.remove(cutter, do_unlink=True)
bevel = body.modifiers.new('Soft engraving lip', 'BEVEL')
bevel.width = .024
bevel.segments = 4
bevel.limit_method = 'ANGLE'
bolt('Frosted engraving base — below glass surface', .6905, .694, etch)

for side in range(4):
    angle = side * math.pi/2
    for j in range(5):
        x, y = (j-2)*.60, 1.99
        px, py = x*math.cos(angle)-y*math.sin(angle), x*math.sin(angle)+y*math.cos(angle)
        dims = (.29, .68, .27) if side%2 == 0 else (.68, .29, .27)
        pin = box(f'Glass terminal {side+1}.{j+1}', (px,py,.37), dims, glass, .12)
        dims = (.11, .51, .07) if side%2 == 0 else (.51, .11, .07)
        box(f'Silver conductor {side+1}.{j+1}', (px,py,.33), dims, silver, .035)

# Broad corner curvature is independent of the shallow tile thickness.
def icon_tile():
    radius, half = 1.06, 2.90
    points = []
    for cx,cy,start in [(half-radius,half-radius,0),(-half+radius,half-radius,90),
                        (-half+radius,-half+radius,180),(half-radius,-half+radius,270)]:
        for step in range(25):
            a = math.radians(start + step*90/24)
            points.append((cx + radius*math.cos(a),cy + radius*math.sin(a)))
    n = len(points)
    verts = [(x,y,z) for z in (-.20,-.02) for x,y in points]
    faces = [tuple(reversed(range(n))),tuple(range(n,2*n))]
    faces += [(i,(i+1)%n,(i+1)%n+n,i+n) for i in range(n)]
    mesh = bpy.data.meshes.new('Native rounded-square tile')
    mesh.from_pydata(verts,[],faces)
    mesh.update()
    obj = bpy.data.objects.new('White rounded icon tile',mesh)
    bpy.context.collection.objects.link(obj)
    # Keep white visible through the glass, but composite camera background as exact white.
    obj.visible_camera = False
    mesh.materials.append(white)
    b = obj.modifiers.new('Subtle tile edge','BEVEL')
    b.width = .035
    b.segments = 4
    obj.modifiers.new('Tile face normals','WEIGHTED_NORMAL')
icon_tile()

# A real glass perimeter, not a painted outline. White remains inside the rim.
rim_curve = bpy.data.curves.new('Continuous glass edge profile', 'CURVE')
rim_curve.dimensions = '3D'
rim_curve.resolution_u = 2
rim_curve.bevel_depth = .044
rim_curve.bevel_resolution = 6
rim_spline = rim_curve.splines.new('POLY')
rim_points = []
for cx,cy,start in [(1.84,1.84,0),(-1.84,1.84,90),(-1.84,-1.84,180),(1.84,-1.84,270)]:
    for step in range(33):
        a = math.radians(start+step*90/32)
        rim_points.append((cx+1.07*math.cos(a),cy+1.07*math.sin(a),-.015,1))
rim_spline.points.add(len(rim_points)-1)
for point,co in zip(rim_spline.points,rim_points):
    point.co = co
rim_spline.use_cyclic_u = True
rim = bpy.data.objects.new('Refractive glass outer icon rim',rim_curve)
bpy.context.collection.objects.link(rim)
rim_curve.materials.append(rim_glass)

def aim(ob, point):
    ob.rotation_euler = (Vector(point)-ob.location).to_track_quat('-Z','Y').to_euler()

def area(name, location, energy, size, target=(0,0,.3), size_y=None):
    bpy.ops.object.light_add(type='AREA', location=location)
    light = bpy.context.object
    light.name = name
    light.data.energy = energy
    light.data.shape = 'RECTANGLE'
    light.data.size = size
    light.data.size_y = size_y or size
    aim(light, target)

area('Large softbox upper left', (-3,2,6), 420, 3, size_y=1.3)
area('Narrow edge strip right', (4,.5,3.2), 280, .8, size_y=5)
area('Top rim light', (0,4,2.4), 210, 3, size_y=.65)
area('Front fill', (-1,-4,5), 110, 3)
for name, pos, dim in [('Left dark card',(-3.2,0,2),(.3,5,4)), ('Top dark card',(0,3.6,2),(5,.2,3))]:
    card = box(name,pos,dim,dark,.02)
    card.visible_camera = False
    card.visible_shadow = False

bpy.ops.object.camera_add(location=(0,-2.0,13))
camera = bpy.context.object
aim(camera,(0,0,.3))
camera.data.type = 'ORTHO'
camera.data.ortho_scale = 6.9
bpy.context.scene.camera = camera
scene = bpy.context.scene
scene.render.engine = 'CYCLES'
scene.cycles.samples = int(os.environ.get('STATE_SAMPLES','64'))
scene.cycles.use_denoising = True
scene.cycles.max_bounces = 16
scene.cycles.transmission_bounces = 12
scene.cycles.glossy_bounces = 8
scene.cycles.transparent_max_bounces = 12
scene.world.use_nodes = True
background = next(n for n in scene.world.node_tree.nodes if n.type == 'BACKGROUND')
background.inputs[0].default_value = (.85,.89,.93,1)
background.inputs[1].default_value = .45
scene.render.film_transparent = True
scene.render.resolution_x = scene.render.resolution_y = int(os.environ.get('STATE_RES','768'))
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = 'PNG'
scene.render.image_settings.color_mode = 'RGBA'
scene.view_settings.view_transform = 'AgX'
scene.view_settings.look = 'AgX - Medium High Contrast'
scene.view_settings.exposure = .65
scene.render.filepath = os.path.join(ROOT,'state-glass-layer.png')
try:
    prefs = bpy.context.preferences.addons['cycles'].preferences
    prefs.compute_device_type = 'METAL'
    prefs.get_devices()
    for device in prefs.devices:
        device.use = device.type == 'METAL'
    if os.environ.get('STATE_DEVICE','CPU') == 'METAL' and any(d.type == 'METAL' for d in prefs.devices):
        scene.cycles.device = 'GPU'
except Exception as error:
    print('Using CPU rendering:',error)
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(ROOT,'state-icon.blend'))
bpy.ops.render.render(write_still=True)
# Composite in linear light over exact white, without applying the scene view transform twice.
image = bpy.data.images.load(scene.render.filepath, check_existing=False)
pixels = list(image.pixels)
for i in range(0,len(pixels),4):
    a = pixels[i+3]
    pixels[i] = pixels[i]*a + (1-a)
    pixels[i+1] = pixels[i+1]*a + (1-a)
    pixels[i+2] = pixels[i+2]*a + (1-a)
    pixels[i+3] = 1
image.pixels = pixels
image.filepath_raw = os.path.join(ROOT,'state-blender-preview.png')
image.file_format = 'PNG'
image.save()
