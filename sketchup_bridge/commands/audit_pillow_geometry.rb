# frozen_string_literal: true

$VERBOSE = nil

load File.expand_path('../utils.rb', __dir__)
load File.expand_path('../../scripts/extendable-bed/extendable-bed.rb', __dir__)

cleared = SketchupBridgeUtils.delete_root_proposal_circles
puts "[rebuild] cleared #{cleared} proposal circle(s)." if cleared.positive?

config = Timmerman::ExtendableBed::Config.new(debug_color: :off)
Timmerman::ExtendableBed.clear
Timmerman::ExtendableBed::BedLayout.new(config).create

model = Sketchup.active_model

def pillow_groups_from_entities(entities, out)
  entities.grep(Sketchup::Group).each do |g|
    out << g if g.name.to_s.downcase.include?('pillow')
    pillow_groups_from_entities(g.entities, out)
  end
end

def face_outward?(face, bbox_center)
  c = face.bounds.center
  v = Geom::Vector3d.new(c.x - bbox_center.x, c.y - bbox_center.y, c.z - bbox_center.z)
  return true if v.length <= 1e-6

  v.normalize!
  n = face.normal.clone
  n.normalize!
  v.dot(n) >= 0
end

pillows = []
pillow_groups_from_entities(model.entities, pillows)
pillows.uniq!

puts "[pillow-audit] groups=#{pillows.length}"
overall_fail = false

pillows.each do |g|
  faces = g.entities.grep(Sketchup::Face).select(&:valid?)
  edges = g.entities.grep(Sketchup::Edge).select(&:valid?)
  bb = Geom::BoundingBox.new
  faces.each { |f| f.vertices.each { |v| bb.add(v.position) } }
  bbox_center = bb.center

  reversed = faces.count { |f| !face_outward?(f, bbox_center) }
  boundary = edges.count { |e| e.faces.length == 1 }
  nonmanifold = edges.count { |e| e.faces.length > 2 }
  zero_face_edges = edges.count { |e| e.faces.empty? }
  soft = edges.count(&:soft?)
  smooth = edges.count(&:smooth?)
  tris = faces.length
  verts = g.entities.grep(Sketchup::Vertex).length

  pass = reversed.zero? && nonmanifold.zero? && boundary.zero? && zero_face_edges.zero?
  overall_fail ||= !pass

  puts format(
    '[pillow-audit] %<status>s name=%<name>s tris=%<tris>d verts=%<verts>d faces=%<faces>d edges=%<edges>d reversed=%<rev>d boundary=%<boundary>d nonmanifold=%<nonmanifold>d zero_face_edges=%<zfe>d soft=%<soft>d smooth=%<smooth>d',
    status: pass ? 'PASS' : 'FAIL',
    name: g.name.inspect,
    tris: tris,
    verts: verts,
    faces: faces.length,
    edges: edges.length,
    rev: reversed,
    boundary: boundary,
    nonmanifold: nonmanifold,
    zfe: zero_face_edges,
    soft: soft,
    smooth: smooth
  )
end

puts(overall_fail ? '[pillow-audit] OVERALL=FAIL' : '[pillow-audit] OVERALL=PASS')
'OK'
