import Foundation
import Testing

@testable import TailscodeCore

/// The shape of an ask, checked where it is decided rather than where it is drawn: the frame maths,
/// what the switches quietly do and do not apply to, and the graph the whole recipe becomes.
struct ImageGenRecipeTests {
    @Test func everyFrameIsSamplerSizedAndKeepsItsRatio() {
        for aspect in ImageGenAspect.allCases {
            for size in ImageGenSize.allCases {
                let pixels = aspect.pixels(size)
                #expect(pixels.width % 32 == 0 && pixels.height % 32 == 0)
                let asked = Double(aspect.ratio.width) / Double(aspect.ratio.height)
                let got = Double(pixels.width) / Double(pixels.height)
                #expect(abs(log(got) - log(asked)) < 0.06, "\(aspect) at \(size) drifted")
                let megapixels = Double(pixels.width * pixels.height) / 1_000_000
                #expect(
                    abs(megapixels - size.megapixels) < size.megapixels * 0.12,
                    "\(aspect) at \(size) is \(megapixels) MP")
            }
        }
    }

    @Test func sizesAreOrderedAndTheLargestIsTwoThousand() {
        #expect(ImageGenAspect.square.pixels(.large).width == 2048)
        #expect(ImageGenAspect.square.pixels(.quick).width < ImageGenAspect.square.pixels(.standard).width)
        #expect(ImageGenAspect.wide.pixels(.large).width > ImageGenAspect.wide.pixels(.large).height)
        #expect(ImageGenAspect.tall.pixels(.large).height > ImageGenAspect.tall.pixels(.large).width)
    }

    /// The fast engine has no alpha VAE, four distilled steps and no room for a second pass, so
    /// all three switches are quietly inert beside it rather than lying on the chip row.
    @Test func theFastEngineIgnoresWhatItCannotDo() {
        var recipe = ImageGenRecipe(
            prompt: "a fox", negative: "blurry", engine: .fast, detail: .fine, cutout: true)
        #expect(recipe.words == "a fox")
        #expect(recipe.avoids == "")
        #expect(recipe.guidance == 1.0)
        #expect(recipe.steps == 4)
        recipe.engine = .quality
        #expect(recipe.words.hasPrefix(ImageGenRecipe.cutoutPreamble))
        #expect(recipe.words.hasSuffix(ImageGenRecipe.cutoutCoda))
        #expect(recipe.avoids == "blurry")
        #expect(recipe.guidance > 1.0, "an avoid list at cfg 1 is a box that does nothing")
        #expect(recipe.steps == 40)
    }

    @Test func aBriefThatAlreadySaysRGBAIsNotSaidTwice() {
        let recipe = ImageGenRecipe(
            prompt: "This is an RGBA image with transparency. A red teapot.", cutout: true)
        #expect(recipe.words.hasPrefix("This is an RGBA"))
        #expect(!recipe.words.contains("RGBA image with transparency. This is"))
    }

    @Test func theGraphCarriesEveryReferenceInTheOrderTheWordsAddressThem() throws {
        let recipe = ImageGenRecipe(
            prompt: "put the shirt from <image2> on the model in <image1>", engine: .quality,
            mode: .edit, seed: 9, references: ["model.png", "shirt.png [output]"])
        let graph = ImageGenClient.graph(recipe)
        var loaders: [String: [String: Any]] = [:]
        for (id, node) in graph {
            guard let node = node as? [String: Any],
                node["class_type"] as? String == "LoadImage"
            else { continue }
            loaders[id] = node
        }
        #expect(loaders.count == 2)
        let encode = try #require(graph["68"] as? [String: Any])
        let inputs = try #require(encode["inputs"] as? [String: Any])
        let first = try #require(inputs["images.image_1"] as? [Any])
        let second = try #require(inputs["images.image_2"] as? [Any])
        let firstID = try #require(first[0] as? String)
        let secondID = try #require(second[0] as? String)
        #expect((loaders[firstID]?["inputs"] as? [String: Any])?["image"] as? String == "model.png")
        #expect(
            (loaders[secondID]?["inputs"] as? [String: Any])?["image"] as? String
                == "shirt.png [output]")
        let sampler = try #require((graph["65"] as? [String: Any])?["inputs"] as? [String: Any])
        let latent = try #require(sampler["latent_image"] as? [Any])
        #expect(latent[0] as? String == "68", "an edit takes the encoder's own latent")
    }

    @Test func aPaintingCarriesItsFrameItsStepsAndItsGuidance() throws {
        let recipe = ImageGenRecipe(
            prompt: "a lighthouse", negative: "people", aspect: .wide, size: .large,
            detail: .draft, seed: 4)
        let graph = ImageGenClient.graph(recipe)
        let latent = try #require((graph["66"] as? [String: Any])?["inputs"] as? [String: Any])
        #expect(latent["width"] as? Int == recipe.pixels.width)
        #expect(latent["height"] as? Int == recipe.pixels.height)
        let sampler = try #require((graph["65"] as? [String: Any])?["inputs"] as? [String: Any])
        #expect(sampler["steps"] as? Int == 15)
        #expect(sampler["cfg"] as? Double == 2.5)
        #expect(sampler["seed"] as? Int == 4)
        let encode = try #require((graph["68"] as? [String: Any])?["inputs"] as? [String: Any])
        #expect(encode["negative_prompt"] as? String == "people")
        let classes = graph.values.compactMap { ($0 as? [String: Any])?["class_type"] as? String }
        #expect(!classes.contains("LoadImage"))
    }

    @Test func theFastEngineStillPaintsAndStillEdits() throws {
        let paint = ImageGenClient.graph(
            ImageGenRecipe(prompt: "a fox", engine: .fast, aspect: .screen, size: .quick, seed: 2))
        let frame = try #require((paint["66"] as? [String: Any])?["inputs"] as? [String: Any])
        #expect(frame["width"] as? Int == ImageGenAspect.screen.pixels(.quick).width)
        let edit = ImageGenClient.graph(
            ImageGenRecipe(
                prompt: "a hat", engine: .fast, mode: .edit, seed: 2, references: ["ref.png"]))
        let editClasses = edit.values.compactMap { ($0 as? [String: Any])?["class_type"] as? String }
        #expect(editClasses.contains("VAEEncode"))
    }

    @Test func aHeldSeedRepeatsAndAReleasedOneRolls() {
        var seed = ImageGenSeed()
        let first = seed.next()
        #expect(seed.last == first)
        seed.hold()
        #expect(seed.isHeld)
        #expect(seed.next() == first)
        #expect(seed.next() == first, "a held seed is the whole point of holding it")
        seed.release()
        var rolled = Set<UInt64>()
        for _ in 0..<8 { rolled.insert(seed.next()) }
        #expect(rolled.count > 1, "a released seed rolls")
        #expect(seed.chip.contains("rolls"))
    }

    @Test func aSlotGathersItsOwnRecipe() {
        var slot = ImageGenSlot(endpoint: ImageGenEndpoint(host: "box"))
        slot.setSize(.large)
        slot.setDetail(.fine)
        slot.setNegative("text, watermark")
        slot.setCutout(true)
        slot.attach(ImageGenReference(path: "/tmp/a.png", kept: ImageGenLibraryItem(filename: "a.png")))
        slot.attach(ImageGenReference(path: "/tmp/b.png"))
        slot.attach(ImageGenReference(path: "/tmp/a.png"))
        #expect(slot.references.count == 2, "the same picture twice is one picture")
        #expect(slot.mode == .edit)
        #expect(!slot.applies(.aspect), "an edit takes its shape from what it starts from")
        let recipe = slot.recipe(prompt: "a fox", seed: 3)
        #expect(recipe.references == ["a.png [output]", "b.png"])
        #expect(recipe.size == .large && recipe.detail == .fine && recipe.cutout)
        #expect(recipe.avoids == "text, watermark")
        slot.release("/tmp/a.png")
        slot.release("/tmp/b.png")
        #expect(slot.mode == .generate && slot.applies(.aspect))
    }

    @Test func theFastEngineOffersNoDetailChip() {
        var slot = ImageGenSlot(endpoint: ImageGenEndpoint(host: "box"))
        #expect(slot.applies(.detail))
        slot.setEngine(.fast)
        #expect(!slot.applies(.detail))
        #expect(!slot.cutoutApplies && !slot.negativeApplies)
    }
}

/// The studio's half of prompting: knowing a thin brief when it sees one, and reading back what a
/// model answered when it was asked to thicken one.
struct ImageGenBriefTests {
    @Test func thinnessIsAboutTheShapeNotOnlyTheLength() {
        #expect(ImageGenBrief.isThin("cat astronaut"))
        #expect(ImageGenBrief.isThin("a coffee shop menu board"))
        #expect(!ImageGenBrief.isThin(""))
        #expect(
            !ImageGenBrief.isThin("The image is a square logo"),
            "somebody who opens like a description knows the shape")
        let long = ImageGenBrief.examples[0].prompt
        #expect(!ImageGenBrief.isThin(long))
        #expect(ImageGenBrief.words(in: long) > ImageGenBrief.thinWordCount)
    }

    @Test func anExpansionIsFoundEvenWhenTheModelWrappedIt() throws {
        let answer = """
            Sure — here you go:
            ```json
            {"rewritten_prompt": "The image is a wide realistic photograph of a fox.", "wh_ratio": "3:2"}
            ```
            """
        let read = try #require(ImageGenBrief.readExpansion(answer))
        #expect(read.prompt == "The image is a wide realistic photograph of a fox.")
        #expect(read.aspect == .landscape)
        #expect(ImageGenBrief.readExpansion("no json here") == nil)
        #expect(ImageGenBrief.readExpansion("{\"rewritten_prompt\": \"  \"}") == nil)
    }

    @Test func everyRatioLandsOnAChipTheStudioActuallyOffers() {
        #expect(ImageGenBrief.aspect(forRatio: "1:1") == .square)
        #expect(ImageGenBrief.aspect(forRatio: "2:3") == .portrait)
        #expect(ImageGenBrief.aspect(forRatio: "16:9") == .screen)
        #expect(ImageGenBrief.aspect(forRatio: "9:16") == .tall)
        #expect(ImageGenBrief.aspect(forRatio: "21:9") == .wide)
        #expect(ImageGenBrief.aspect(forRatio: "4:5") == .portrait, "the nearest shape, not none")
        #expect(ImageGenBrief.aspect(forRatio: "nonsense") == nil)
    }

    @Test func theExamplesAreWhatTheRulesAskFor() {
        for example in ImageGenBrief.examples where example.id != "cutout" {
            #expect(!ImageGenBrief.isThin(example.prompt), "\(example.id) is thin")
            #expect(
                example.prompt.lowercased().contains("lighting is"),
                "\(example.id) never says where the light comes from")
            #expect(
                example.prompt.lowercased().contains("overall composition"),
                "\(example.id) never closes on the frame")
        }
        #expect(ImageGenBrief.rules.count == 6)
        #expect(ImageGenBrief.scaffold.contains("<subject>"))
        #expect(ImageGenBrief.expansionAsk("a fox").contains("a fox"))
    }
}
