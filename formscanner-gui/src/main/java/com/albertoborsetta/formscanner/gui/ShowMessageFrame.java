package com.albertoborsetta.formscanner.gui;

import com.albertoborsetta.formscanner.commons.FormScannerConstants.Frame;
import com.albertoborsetta.formscanner.commons.translation.FormScannerTranslation;
import com.albertoborsetta.formscanner.commons.translation.FormScannerTranslationKeys;
import com.albertoborsetta.formscanner.controller.MessageController;
import com.albertoborsetta.formscanner.gui.builder.ButtonBuilder;
import com.albertoborsetta.formscanner.gui.builder.PanelBuilder;
import com.albertoborsetta.formscanner.model.FormScannerModel;
import java.awt.BorderLayout;
import javax.swing.JButton;
import javax.swing.JLabel;
import javax.swing.JPanel;
import javax.swing.SpringLayout;

public class ShowMessageFrame extends InternalFrame implements View {

    private final JLabel messageLabel;
    private final JButton okButton;
    private final MessageController messageController;
    
    
    public ShowMessageFrame(FormScannerModel model) {
        
        super(model);
        messageController = new MessageController(model);
        messageController.add(this);
        
        setBounds(model.getLastPosition(Frame.SHOW_MESSAGE_FRAME));
        setName(Frame.SHOW_MESSAGE_FRAME.name());
        setClosable(true);
        setLayout(new BorderLayout());

        messageLabel = new JLabel("<html><body>Guide:<br>Student names should be separated with semicolon. Example:<br>&lt;last name&gt;-&lt;first name&gt;;&lt;last name&gt;-&lt;first name&gt;</body></html>");
        okButton = new ButtonBuilder(orientation)
                .withText(FormScannerTranslation.getTranslationFor(FormScannerTranslationKeys.OK_BUTTON))
//                .withActionCommand(FormScannerConstants.CHOOSE_RENAME_NAMES_FILE)
                .withActionListener(messageController).build();
        
        add(messageLabel, BorderLayout.NORTH);
        
        JPanel buttonPanel = new PanelBuilder(orientation)
                .withLayout(new SpringLayout()).add(okButton)
                .withGrid(1, 1).build();
        
        add(buttonPanel, BorderLayout.SOUTH);
        
        setTitle(FormScannerTranslation
                .getTranslationFor(FormScannerTranslationKeys.SHOW_MESSAGE_FRAME_TITLE));
        
    }

}
