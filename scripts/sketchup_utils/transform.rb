# frozen_string_literal: true

# Pure-Ruby 4x4 affine transform value object. Backend-agnostic: backends
# (SketchUp, OBJ exporter, test doubles, …) convert to their native matrix
# type at the API boundary.
#
# Internally stored as a row-major 4x4 array; matrix-times-matrix and
# matrix-times-point are provided. Built from factory methods — callers never
# touch the raw matrix.

module Timmerman
  module SketchupUtils
    class Transform
      # @param matrix [Array<Array(Float,Float,Float,Float)>] 4 rows × 4 cols.
      attr_reader :matrix

      def initialize(matrix)
        @matrix = matrix.map(&:dup).freeze
      end

      def self.identity
        new([
              [1.0, 0.0, 0.0, 0.0],
              [0.0, 1.0, 0.0, 0.0],
              [0.0, 0.0, 1.0, 0.0],
              [0.0, 0.0, 0.0, 1.0]
            ])
      end

      # Translation by [x, y, z] (SketchUp Length or Numeric).
      def self.translation(vec)
        x, y, z = vec
        new([
              [1.0, 0.0, 0.0, x.to_f],
              [0.0, 1.0, 0.0, y.to_f],
              [0.0, 0.0, 1.0, z.to_f],
              [0.0, 0.0, 0.0, 1.0]
            ])
      end

      # 180° rotation about the +Y axis (flips +X/+Z sign while preserving Y).
      # Used by the construction-step "upside-down" row.
      def self.rotation_y_180
        new([
              [-1.0, 0.0,  0.0, 0.0],
              [ 0.0, 1.0,  0.0, 0.0],
              [ 0.0, 0.0, -1.0, 0.0],
              [ 0.0, 0.0,  0.0, 1.0]
            ])
      end

      # self * other (apply +other+ first, then +self+).
      def *(other)
        raise ArgumentError, 'expected Transform' unless other.is_a?(Transform)

        a = @matrix
        b = other.matrix
        out = Array.new(4) { Array.new(4, 0.0) }
        4.times do |i|
          4.times do |j|
            sum = 0.0
            4.times { |k| sum += a[i][k] * b[k][j] }
            out[i][j] = sum
          end
        end
        self.class.new(out)
      end
    end
  end
end
